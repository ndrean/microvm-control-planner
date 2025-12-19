defmodule FcExCp.VM do
  @moduledoc """
  Individual VM LifeCycle

  One GenServer = one microVM lifecycle
  - creates TAP
  - starts firecracker --api-sock ...
  - configures VM via unix-socket HTTP
  - starts instance
  - waits for Phoenix health endpoint
  - returns {ip, port} to Manager
  """

  use GenServer
  require Logger

  alias FcExCp.Firecracker.HTTP, as: FCH
  alias FcExCp.{Config, Net, Proxy, TelemetryEvents}

  defstruct [
    :id,
    :tenant,
    :api_sock,
    :metrics_path,
    :tap,
    :ip,
    :mac,
    :fc_port,
    :fc_port_handle,
    :fc_pid
  ]

  # Public lookup
  def via(id), do: {:via, Registry, {FcExCp.Registry, {:vm, id}}}

  @spec start_link(nil | maybe_improper_list() | map()) ::
          :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def info(id), do: GenServer.call(via(id), :info)
  def boot(id), do: GenServer.call(via(id), :boot, 60_000)
  def stop(id), do: GenServer.stop(via(id), :normal)

  @impl true
  def init(opts) do
    id = opts[:id] || new_id()
    tenant = opts[:tenant]
    ip = opts[:ip] || ip_for_id(id)
    port = Config.guest_port()

    st = %__MODULE__{
      id: id,
      tenant: tenant,
      api_sock: "/tmp/fc-#{id}.sock",
      metrics_path: "/run/firecracker/fc-#{id}.metrics",
      tap: "tap-#{id}",
      ip: ip,
      mac: random_mac(),
      fc_port: port
    }

    # the metrics_path & fc_pid are stored to avoid
    # asking to the VM process

    {:ok, st}
  end

  @impl true
  def handle_call(:info, _from, st) do
    {:reply,
     %{
       id: st.id,
       tenant: st.tenant,
       ip: st.ip,
       port: st.fc_port,
       tap: st.tap,
       api_sock: st.api_sock,
       metrics_path: st.metrics_path,
       pid: st.fc_pid
     }, st}
  end

  @impl true
  def handle_call(:boot, _from, st) do
    boot_start = System.monotonic_time(:millisecond)

    try do
      File.rm(st.api_sock)
      File.rm(st.metrics_path)
      :ok = Net.create_tap!(st.tap)

      # Start firecracker process
      port = start_firecracker!(st.api_sock, st.metrics_path)
      {:os_pid, pid} = Port.info(port, :os_pid)
      st = %{st | fc_port_handle: port, fc_pid: pid}

      # Configure via API
      configure_firecracker!(st)

      # Start instance
      :ok = ensure_ok!(FCH.put(st.api_sock, "/actions", %{"action_type" => "InstanceStart"}))

      # Wait for app readiness
      :ok = wait_http_200!("http://#{st.ip}:#{st.fc_port}/health", 10_000)

      # Register with proxy (optional)
      Proxy.register(st.tenant, st.ip, st.fc_port)

      boot_duration_ms = System.monotonic_time(:millisecond) - boot_start

      Logger.info(
        "VM ready id=#{st.id} tenant=#{inspect(st.tenant)} ip=#{st.ip}:#{st.fc_port} duration=#{boot_duration_ms}ms"
      )

      # Emit telemetry: VM boot successful
      TelemetryEvents.vm_booted(st.id, boot_duration_ms, %{
        tenant: inspect(st.tenant),
        ip: st.ip,
        port: st.fc_port
      })

      {:reply, {:ok, %{id: st.id, ip: st.ip, port: st.fc_port}}, st}
    rescue
      e ->
        error_msg = Exception.message(e)
        Logger.error("VM boot failed id=#{st.id}: #{error_msg}")

        # Emit telemetry: VM boot failed
        TelemetryEvents.vm_boot_failed(st.id, e, %{
          tenant: inspect(st.tenant),
          error: error_msg
        })

        cleanup(st)
        {:reply, {:error, e}, st}
    end
  end

  @impl true
  def terminate(_reason, st) do
    # Emit telemetry: VM shutdown
    TelemetryEvents.vm_shutdown(st.id, :normal, %{
      tenant: inspect(st.tenant)
    })

    cleanup(st)
    :ok
  end

  defp cleanup(st) do
    Proxy.deregister(st.tenant)

    if is_port(st.fc_port_handle) do
      Port.close(st.fc_port_handle)
    end

    Net.delete_tap(st.tap)
    File.rm(st.api_sock)
    :ok
  end

  defp configure_firecracker!(st) do
    kernel = Config.kernel_path()
    rootfs = Config.rootfs_path()

    :ok =
      ensure_ok!(
        FCH.put(st.api_sock, "/machine-config", %{
          "vcpu_count" => 2,
          "mem_size_mib" => 512,
          "smt" => false
        })
      )

    :ok =
      ensure_ok!(
        FCH.put(st.api_sock, "/boot-source", %{
          "kernel_image_path" => kernel,
          "boot_args" => "console=ttyS0 reboot=k panic=1 pci=off init=/init"
        })
      )

    :ok =
      ensure_ok!(
        FCH.put(st.api_sock, "/drives/rootfs", %{
          "drive_id" => "rootfs",
          "path_on_host" => rootfs,
          "is_root_device" => true,
          "is_read_only" => false
        })
      )

    :ok =
      ensure_ok!(
        FCH.put(st.api_sock, "/network-interfaces/eth0", %{
          "iface_id" => "eth0",
          "guest_mac" => st.mac,
          "host_dev_name" => st.tap
        })
      )

    :ok
  end

  defp ensure_ok!({:ok, %{status: s} = _resp}) when s in 200..299, do: :ok
  defp ensure_ok!({:ok, resp}), do: raise("Firecracker API error: #{inspect(resp)}")
  defp ensure_ok!({:error, reason}), do: raise("Firecracker API error: #{inspect(reason)}")

  defp start_firecracker!(api_sock, metrics_path) do
    exe = System.find_executable("firecracker") || raise "firecracker not in PATH"

    args = [
      "--api-sock",
      api_sock,
      "--metrics-path",
      metrics_path
    ]

    Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args])
  end

  defp wait_http_200!(url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    urlc = String.to_charlist(url)

    poll = fn poll ->
      if System.monotonic_time(:millisecond) > deadline do
        raise "health timeout for #{url}"
      end

      case :httpc.request(:get, {urlc, []}, [timeout: 700], []) do
        {:ok, {{_, 200, _}, _h, _b}} ->
          :ok

        _ ->
          Process.sleep(150)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  defp new_id do
    Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp ip_for_id(id) do
    # stable-ish mapping from id -> last octet
    <<_::binary-5, last::8, _::binary>> = :crypto.hash(:sha256, id)
    last_octet = 2 + rem(last, 200)
    Config.subnet_prefix() <> Integer.to_string(last_octet)
  end

  defp random_mac do
    <<a, b, c, d, e>> = :crypto.strong_rand_bytes(5)
    # locally administered
    first = Bitwise.bor(Bitwise.band(a, 0xFE), 0x02)
    bytes = [first, b, c, d, e, 1]
    Enum.map_join(bytes, ":", fn x -> Base.encode16(<<x>>, case: :lower) end)
  end
end
