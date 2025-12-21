defmodule FcExCp.VM do
  @moduledoc """
  Individual VM LifeCycle

  One GenServer = one microVM lifecycle
  Supports both Firecracker and Cloud Hypervisor backends
  """

  use GenServer
  require Logger

  alias FcExCp.Firecracker.HTTP, as: FCH
  alias FcExCp.{Config, Net, Proxy, TelemetryEvents}

  @type backend :: :firecracker | :cloud_hypervisor
  @type vm_state :: %__MODULE__{}

  defstruct [
    :id,
    :tenant,
    :backend,
    :api_sock,
    :metrics_path,
    :tap,
    :ip,
    :mac,
    :fc_port,
    :fc_port_handle,
    :fc_pid,
    :config,
    status: :created
  ]

  # Public API
  def via(id), do: {:via, Registry, {FcExCp.Registry, {:vm, id}}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def info(id), do: GenServer.call(via(id), :info)
  def boot(id), do: GenServer.call(via(id), :boot, 60_000)
  def stop(id), do: GenServer.stop(via(id), :normal)
  def status(id), do: GenServer.call(via(id), :status)

  @impl true
  def init(opts) do
    id = opts[:id] || new_id()
    tenant = opts[:tenant]

    # Determine backend (default to cloud_hypervisor on macOS)
    backend = opts[:backend] || default_backend()

    ip = opts[:ip] || ip_for_id(id)
    port = Config.guest_port()

    config = %{
      vcpus: opts[:vcpus] || 2,
      memory_mb: opts[:memory_mb] || 512,
      kernel_path: opts[:kernel_path] || Config.kernel_path(),
      rootfs_path: opts[:rootfs_path] || Config.rootfs_path(),
      boot_args: opts[:boot_args] || default_boot_args(backend)
    }

    st = %__MODULE__{
      id: id,
      tenant: tenant,
      backend: backend,
      api_sock: api_socket_path(id, backend),
      metrics_path: metrics_path(id, backend),
      tap: "tap-#{id}",
      ip: ip,
      mac: random_mac(),
      fc_port: port,
      config: config,
      status: :created
    }

    Logger.debug("VM #{id} initialized with backend #{backend}")
    {:ok, st}
  end

  @impl true
  def handle_call(:info, _from, st) do
    {:reply,
     %{
       id: st.id,
       tenant: st.tenant,
       backend: st.backend,
       ip: st.ip,
       port: st.fc_port,
       tap: st.tap,
       api_sock: st.api_sock,
       metrics_path: st.metrics_path,
       pid: st.fc_pid,
       status: st.status,
       config: st.config
     }, st}
  end

  def handle_call(:status, _from, st) do
    {:reply, st.status, st}
  end

  def handle_call(:boot, _from, st) do
    boot_start = System.monotonic_time(:millisecond)

    try do
      # Update state to booting
      st = %{st | status: :booting}

      # Cleanup previous runs
      cleanup_files(st)

      # Create TAP interface (handles macOS differences)
      :ok = Net.create_tap!(st.tap, st.backend)

      # Start the hypervisor
      {port, pid} = start_hypervisor!(st)
      st = %{st | fc_port_handle: port, fc_pid: pid, status: :starting}

      # Configure VM
      :ok = configure_hypervisor!(st)

      # Start instance
      :ok = start_instance!(st)

      # Wait for app readiness
      :ok = wait_http_200!("http://#{st.ip}:#{st.fc_port}/health", 15_000)

      # Register with proxy
      Proxy.register(st.tenant, st.ip, st.fc_port)

      boot_duration_ms = System.monotonic_time(:millisecond) - boot_start

      Logger.info(
        "VM ready id=#{st.id} backend=#{st.backend} ip=#{st.ip}:#{st.fc_port} duration=#{boot_duration_ms}ms"
      )

      TelemetryEvents.vm_booted(st.id, boot_duration_ms, %{
        tenant: inspect(st.tenant),
        backend: inspect(st.backend),
        ip: st.ip,
        port: st.fc_port
      })

      st = %{st | status: :running}
      {:reply, {:ok, %{id: st.id, ip: st.ip, port: st.fc_port}}, st}
    rescue
      e ->
        error_msg = Exception.message(e)
        Logger.error("VM boot failed id=#{st.id}: #{error_msg}")

        TelemetryEvents.vm_boot_failed(st.id, e, %{
          tenant: inspect(st.tenant),
          backend: inspect(st.backend),
          error: error_msg
        })

        cleanup(st)
        st = %{st | status: :failed}
        {:reply, {:error, e}, st}
    end
  end

  @impl true
  def terminate(_reason, st) do
    TelemetryEvents.vm_shutdown(st.id, :normal, %{
      tenant: inspect(st.tenant),
      backend: inspect(st.backend)
    })

    cleanup(st)
    :ok
  end

  # Private Implementation

  defp cleanup(st) do
    Proxy.deregister(st.tenant)

    if is_port(st.fc_port_handle) do
      Port.close(st.fc_port_handle)
    end

    # Kill hypervisor process if still running
    if st.fc_pid && Process.alive?(st.fc_pid) do
      System.cmd("kill", ["-9", to_string(st.fc_pid)])
    end

    Net.delete_tap(st.tap, st.backend)
    cleanup_files(st)

    :ok
  end

  defp cleanup_files(st) do
    File.rm(st.api_sock)
    File.rm(st.metrics_path)

    # Cleanup potential stale files
    for path <- [st.api_sock, st.metrics_path, "#{st.api_sock}.old"] do
      File.rm(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Hypervisor-specific configuration
  defp configure_hypervisor!(%{backend: :firecracker} = st) do
    with :ok <- configure_firecracker_machine(st),
         :ok <- configure_firecracker_boot(st),
         :ok <- configure_firecracker_drive(st),
         :ok <- configure_firecracker_network(st) do
      :ok
    else
      error -> raise "Firecracker configuration failed: #{inspect(error)}"
    end
  end

  defp configure_hypervisor!(%{backend: :cloud_hypervisor} = st) do
    # Cloud Hypervisor uses command-line args, not HTTP API
    # Configuration is done in start_hypervisor!/1
    :ok
  end

  defp configure_firecracker_machine(st) do
    ensure_ok!(
      FCH.put(st.api_sock, "/machine-config", %{
        "vcpu_count" => st.config.vcpus,
        "mem_size_mib" => st.config.memory_mb,
        "smt" => false
      })
    )
  end

  defp configure_firecracker_boot(st) do
    ensure_ok!(
      FCH.put(st.api_sock, "/boot-source", %{
        "kernel_image_path" => st.config.kernel_path,
        "boot_args" => st.config.boot_args
      })
    )
  end

  defp configure_firecracker_drive(st) do
    ensure_ok!(
      FCH.put(st.api_sock, "/drives/rootfs", %{
        "drive_id" => "rootfs",
        "path_on_host" => st.config.rootfs_path,
        "is_root_device" => true,
        "is_read_only" => false
      })
    )
  end

  defp configure_firecracker_network(st) do
    ensure_ok!(
      FCH.put(st.api_sock, "/network-interfaces/eth0", %{
        "iface_id" => "eth0",
        "guest_mac" => st.mac,
        "host_dev_name" => st.tap
      })
    )
  end

  defp start_instance!(%{backend: :firecracker} = st) do
    ensure_ok!(FCH.put(st.api_sock, "/actions", %{"action_type" => "InstanceStart"}))
  end

  defp start_instance!(%{backend: :cloud_hypervisor} = st) do
    # Cloud Hypervisor starts automatically
    :ok
  end

  defp ensure_ok!({:ok, %{status: s}}) when s in 200..299, do: :ok
  defp ensure_ok!({:ok, resp}), do: raise("API error: #{inspect(resp)}")
  defp ensure_ok!({:error, reason}), do: raise("API error: #{inspect(reason)}")

  defp start_hypervisor!(%{backend: :firecracker} = st) do
    exe =
      System.find_executable("firecracker") ||
        raise "firecracker not in PATH. Install with: brew install firecracker"

    args = [
      "--api-sock",
      st.api_sock,
      "--metrics-path",
      st.metrics_path,
      # For development
      "--seccomp-level",
      "0"
    ]

    start_port(exe, args)
  end

  defp start_hypervisor!(%{backend: :cloud_hypervisor} = st) do
    exe =
      System.find_executable("cloud-hypervisor") ||
        System.find_executable("ch") ||
        raise "cloud-hypervisor not in PATH. Install with: brew install cloud-hypervisor"

    # Cloud Hypervisor command line arguments
    args = [
      "--api-socket",
      st.api_sock,
      "--kernel",
      st.config.kernel_path,
      "--disk",
      "path=#{st.config.rootfs_path}",
      "--cpus",
      "boot=#{st.config.vcpus}",
      "--memory",
      "size=#{st.config.memory_mb}M",
      "--net",
      "tap=#{st.tap},mac=#{st.mac},ip=#{st.ip}",
      "--console",
      "off",
      "--serial",
      "tty"
    ]

    start_port(exe, args)
  end

  defp start_port(exe, args) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stream,
        :stderr_to_stdout,
        args: args
      ])

    # Wait a bit for process to start
    Process.sleep(100)

    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        {port, pid}

      _ ->
        Port.close(port)
        raise "Failed to start hypervisor process"
    end
  end

  defp wait_http_200!(url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll, attempts ->
      if System.monotonic_time(:millisecond) > deadline do
        raise "health timeout for #{url} after #{attempts} attempts"
      end

      case Finch.build(:get, url) |> Finch.request(MyFinch) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status}} when status >= 500 ->
          # Server error, retry
          Process.sleep(200)
          poll.(poll, attempts + 1)

        {:error, _} ->
          # Connection error, retry
          Process.sleep(200)
          poll.(poll, attempts + 1)

        _ ->
          Process.sleep(200)
          poll.(poll, attempts + 1)
      end
    end

    poll.(poll, 0)
  end

  # Helper functions
  defp api_socket_path(id, :firecracker), do: "/tmp/fc-#{id}.sock"
  defp api_socket_path(id, :cloud_hypervisor), do: "/tmp/ch-#{id}.sock"

  defp metrics_path(id, :firecracker), do: "/run/firecracker/fc-#{id}.metrics"
  defp metrics_path(id, :cloud_hypervisor), do: "/tmp/ch-#{id}.metrics"

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> :cloud_hypervisor
      _ -> :firecracker
    end
  end

  defp default_boot_args(:firecracker) do
    "console=ttyS0 reboot=k panic=1 pci=off init=/init"
  end

  defp default_boot_args(:cloud_hypervisor) do
    "console=ttyS0 root=/dev/vda rw"
  end

  defp new_id do
    Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp ip_for_id(id) do
    <<_::binary-5, last::8, _::binary>> = :crypto.hash(:sha256, id)
    last_octet = 2 + rem(last, 200)
    Config.subnet_prefix() <> Integer.to_string(last_octet)
  end

  defp random_mac do
    <<a, b, c, d, e>> = :crypto.strong_rand_bytes(5)
    first = Bitwise.bor(Bitwise.band(a, 0xFE), 0x02)
    bytes = [first, b, c, d, e, 1]
    Enum.map_join(bytes, ":", fn x -> Base.encode16(<<x>>, case: :lower) end)
  end
end
