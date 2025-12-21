defmodule FcExCp.Net do
  @moduledoc """
  Host networking with platform-specific implementations.

  Linux: Uses ip/iptables + bridge
  macOS: Uses utun interfaces + packet filtering
  """

  require Logger
  alias FcExCp.Config

  @type platform :: :linux | :macos
  @type tap_result :: :ok | {:error, String.t()}

  @spec ensure_host_network!() :: :ok | no_return()
  def ensure_host_network!() do
    platform = detect_platform()

    case platform do
      :linux -> ensure_host_network_linux!()
      :macos -> ensure_host_network_macos!()
    end
  end

  @spec create_tap!(String.t()) :: tap_result
  def create_tap!(tap_name) do
    platform = detect_platform()

    case platform do
      :linux -> create_tap_linux!(tap_name)
      :macos -> create_tap_macos!(tap_name)
    end
  end

  @spec delete_tap(String.t()) :: tap_result
  def delete_tap(tap_name) do
    platform = detect_platform()

    case platform do
      :linux -> delete_tap_linux(tap_name)
      :macos -> delete_tap_macos(tap_name)
    end
  end

  # Linux implementation (your original code)
  defp ensure_host_network_linux!() do
    bridge = Config.bridge()
    cidr = Config.bridge_cidr()
    out = Config.outbound_iface() || detect_outbound_iface_linux!()

    # bridge br0
    unless link_exists_linux?(bridge) do
      sh!("ip", ["link", "add", bridge, "type", "bridge"])
      sh!("ip", ["addr", "add", cidr, "dev", bridge])
      sh!("ip", ["link", "set", bridge, "up"])
    end

    # ip_forward
    sh!("sysctl", ["-w", "net.ipv4.ip_forward=1"])

    # NAT rules (idempotency best-effort)
    # MASQUERADE 172.16.0.0/24 -> outbound
    sh!(
      "iptables",
      ["-t", "nat", "-C", "POSTROUTING", "-s", subnet_cidr(), "-o", out, "-j", "MASQUERADE"],
      allow_fail: true
    )

    sh!(
      "iptables",
      ["-t", "nat", "-A", "POSTROUTING", "-s", subnet_cidr(), "-o", out, "-j", "MASQUERADE"],
      allow_fail: true
    )

    sh!("iptables", ["-C", "FORWARD", "-i", bridge, "-o", out, "-j", "ACCEPT"], allow_fail: true)
    sh!("iptables", ["-A", "FORWARD", "-i", bridge, "-o", out, "-j", "ACCEPT"], allow_fail: true)

    sh!(
      "iptables",
      [
        "-C",
        "FORWARD",
        "-i",
        out,
        "-o",
        bridge,
        "-m",
        "state",
        "--state",
        "RELATED,ESTABLISHED",
        "-j",
        "ACCEPT"
      ],
      allow_fail: true
    )

    sh!(
      "iptables",
      [
        "-A",
        "FORWARD",
        "-i",
        out,
        "-o",
        bridge,
        "-m",
        "state",
        "--state",
        "RELATED,ESTABLISHED",
        "-j",
        "ACCEPT"
      ],
      allow_fail: true
    )

    Logger.info("Host network ready: bridge=#{bridge} cidr=#{cidr} out=#{out}")
    :ok
  end

  defp create_tap_linux!(tap_name) do
    bridge = Config.bridge()

    sh!("ip", ["tuntap", "add", tap_name, "mode", "tap"])
    sh!("ip", ["link", "set", tap_name, "master", bridge])
    sh!("ip", ["link", "set", tap_name, "up"])
    :ok
  end

  defp delete_tap_linux(tap_name) do
    _ = sh!("ip", ["link", "del", tap_name], allow_fail: true)
    :ok
  end

  # macOS implementation
  defp ensure_host_network_macos!() do
    # On macOS, we use a different approach since we don't have ip/iptables
    # We'll use a virtual bridge with pf (packet filter)

    # 1. Enable IP forwarding
    sh!("sysctl", ["-w", "net.inet.ip.forwarding=1"])
    sh!("sysctl", ["-w", "net.inet.ip.fw.enable=1"])

    # 2. Set up pf (packet filter) for NAT if not already configured
    setup_pf_nat!()

    # 3. Create a bridge if needed (using ifconfig)
    setup_bridge_macos!()

    Logger.info("macOS host network configured")
    :ok
  end

  defp create_tap_macos!(tap_name) do
    # On macOS, we have a few options:

    # Option 1: Use utun interfaces (VPN-style, requires root/helper)
    # This would require a helper tool or running with sudo

    # Option 2: Use vde_vmnet (easier for development)
    # brew install vde

    # Option 3: Use a user-space TAP implementation
    # We'll go with vde_vmnet for development simplicity

    case detect_vde_vmnet() do
      {:ok, vde_switch} ->
        create_vde_tap!(tap_name, vde_switch)

      {:error, _} ->
        # Fallback to simpler approach for development
        create_simple_tap_macos!(tap_name)
    end
  end

  defp delete_tap_macos(tap_name) do
    # Clean up any created interfaces
    _ = sh!("ifconfig", [tap_name, "destroy"], allow_fail: true)
    :ok
  end

  # Private helper functions

  defp detect_platform() do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _ -> raise "Unsupported platform"
    end
  end

  defp setup_pf_nat!() do
    pf_conf = """
    # FcExCp NAT configuration
    ext_if = "#{detect_outbound_iface_macos!()}"
    vm_net = "#{Config.subnet_prefix()}0"

    nat on $ext_if from $vm_net to any -> ($ext_if)
    pass in quick on $ext_if proto tcp from any to any port 2375
    pass out quick on $ext_if
    """

    # Write temporary pf config
    tmp_conf = "/tmp/fcexcp-pf.conf"
    File.write!(tmp_conf, pf_conf)

    # Load pf rules
    sh!("pfctl", ["-e"], allow_fail: true)
    sh!("pfctl", ["-f", tmp_conf], allow_fail: true)

    File.rm(tmp_conf)
  end

  defp setup_bridge_macos!() do
    bridge = Config.bridge()

    # Check if bridge exists
    case System.cmd("ifconfig", [bridge], stderr_to_stdout: true) do
      {_, 0} ->
        # Bridge exists, bring it up
        sh!("ifconfig", [bridge, "up"])

      _ ->
        # Create bridge
        sh!("ifconfig", [bridge, "create"])
        sh!("ifconfig", [bridge, "inet", Config.bridge_cidr(), "up"])
    end
  end

  defp detect_vde_vmnet() do
    # Check if vde_vmnet is installed and running
    with {:ok, _} <- find_executable("vde_switch"),
         {:ok, _} <- find_executable("vde_vmnet") do
      # Try to connect to existing switch or create one
      switch_pid = find_vde_switch()

      if switch_pid do
        {:ok, switch_pid}
      else
        start_vde_switch()
      end
    else
      _ -> {:error, "vde_vmnet not available"}
    end
  end

  defp create_vde_tap!(tap_name, vde_switch) do
    # Use vde_vmnet to create a tap interface
    # This is a simplified version - you'd need to adapt based on your needs
    sh!("sudo", ["vde_vmnet", "--vmnet-mode", "bridged", "--vmnet-interface", "en0", tap_name])
    :ok
  end

  defp create_simple_tap_macos!(tap_name) do
    # For development/testing without complex networking
    # We'll create a loopback alias instead

    ip = "#{Config.subnet_prefix()}1"

    # Create lo0 alias
    sh!("sudo", ["ifconfig", "lo0", "alias", ip, "up"])

    # Store mapping for cleanup
    store_tap_mapping(tap_name, ip)

    Logger.warn("""
    Using loopback alias for #{tap_name} on macOS.
    This is for development only - VMs won't have external network access.
    For full networking, install vde_vmnet: brew install vde
    """)

    :ok
  end

  defp detect_outbound_iface_linux!() do
    {out, 0} =
      System.cmd("sh", [
        "-lc",
        "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'"
      ])

    String.trim(out)
  end

  defp detect_outbound_iface_macos!() do
    {out, 0} =
      System.cmd("sh", [
        "-lc",
        "route get 1.1.1.1 | awk '/interface:/ {print $2}'"
      ])

    String.trim(out)
  end

  defp link_exists_linux?(name) do
    case System.cmd("ip", ["link", "show", name], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, "#{cmd} not found"}
      path -> {:ok, path}
    end
  end

  defp find_vde_switch() do
    case System.cmd("pgrep", ["-f", "vde_switch"], stderr_to_stdout: true) do
      {output, 0} ->
        pids = String.split(output, "\n", trim: true)
        List.first(pids)

      _ ->
        nil
    end
  end

  defp start_vde_switch() do
    # Start vde_switch in the background
    port =
      Port.open({:spawn_executable, System.find_executable("vde_switch")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-s", "/tmp/vde.ctl", "-tap", "tap0"]
      ])

    # Give it time to start
    Process.sleep(500)
    {:ok, port}
  end

  defp store_tap_mapping(tap_name, ip) do
    # Store in a file or ETS for cleanup
    path = "/tmp/fcexcp-#{tap_name}.ip"
    File.write!(path, ip)
  end

  defp subnet_cidr() do
    # assumes bridge_cidr like 172.16.0.1/24
    [ip, mask] = String.split(Config.bridge_cidr(), "/", parts: 2)
    # Turn 172.16.0.1 -> 172.16.0.0/24
    base = ip |> String.split(".") |> List.replace_at(3, "0") |> Enum.join(".")
    "#{base}/#{mask}"
  end

  defp sh!(cmd, args, opts \\ []) do
    allow_fail = Keyword.get(opts, :allow_fail, false)
    use_sudo = Keyword.get(opts, :sudo, false)

    full_cmd = if use_sudo, do: ["sudo", cmd | args], else: [cmd | args]

    case System.cmd("sh", ["-c", Enum.join(full_cmd, " ")], stderr_to_stdout: true) do
      {out, 0} ->
        out

      {out, code} ->
        if allow_fail do
          out
        else
          raise "Command failed: #{Enum.join(full_cmd, " ")} (#{code})\n#{out}"
        end
    end
  end
end
