defmodule FcExCp.Net do
  @moduledoc """
  Host networking for Firecracker and Cloud Hypervisor

  Platform-specific TAP interface management:
  - Linux: Uses ip/iptables for both backends
  - macOS: Cloud Hypervisor only (Firecracker not supported on ARM64)
  """

  require Logger
  alias FcExCp.Config

  @type backend :: :firecracker | :cloud_hypervisor

  @doc """
  Ensures host network is configured (bridge, NAT, forwarding)
  """
  @spec ensure_host_network!() :: :ok | no_return()
  def ensure_host_network!() do
    case platform() do
      :linux -> ensure_host_network_linux!()
      :macos -> ensure_host_network_macos!()
    end
  end

  @doc """
  Creates a TAP interface for the given backend
  """
  @spec create_tap!(String.t(), backend()) :: :ok | no_return()
  def create_tap!(tap_name, backend) do
    case platform() do
      :linux -> create_tap_linux!(tap_name)
      :macos -> create_tap_macos!(tap_name, backend)
    end
  end

  @doc """
  Deletes a TAP interface
  """
  @spec delete_tap(String.t(), backend()) :: :ok
  def delete_tap(tap_name, backend) do
    case platform() do
      :linux -> delete_tap_linux(tap_name)
      :macos -> delete_tap_macos(tap_name, backend)
    end
  end

  # Platform detection
  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      other -> raise "Unsupported platform: #{inspect(other)}"
    end
  end

  # ========================================================================
  # Linux Implementation (ip + iptables)
  # ========================================================================

  defp ensure_host_network_linux! do
    bridge = Config.bridge()
    cidr = Config.bridge_cidr()
    out = Config.outbound_iface() || detect_outbound_iface_linux!()

    # Create bridge if needed
    unless link_exists_linux?(bridge) do
      sh!("ip", ["link", "add", bridge, "type", "bridge"])
      sh!("ip", ["addr", "add", cidr, "dev", bridge])
      sh!("ip", ["link", "set", bridge, "up"])
    end

    # Enable IP forwarding
    sh!("sysctl", ["-w", "net.ipv4.ip_forward=1"])

    # NAT rules (idempotent - check before adding)
    subnet = subnet_cidr()

    # MASQUERADE rule
    sh!("iptables", ["-t", "nat", "-C", "POSTROUTING", "-s", subnet, "-o", out, "-j", "MASQUERADE"], allow_fail: true)
    sh!("iptables", ["-t", "nat", "-A", "POSTROUTING", "-s", subnet, "-o", out, "-j", "MASQUERADE"], allow_fail: true)

    # FORWARD rules
    sh!("iptables", ["-C", "FORWARD", "-i", bridge, "-o", out, "-j", "ACCEPT"], allow_fail: true)
    sh!("iptables", ["-A", "FORWARD", "-i", bridge, "-o", out, "-j", "ACCEPT"], allow_fail: true)

    sh!("iptables", ["-C", "FORWARD", "-i", out, "-o", bridge, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"], allow_fail: true)
    sh!("iptables", ["-A", "FORWARD", "-i", out, "-o", bridge, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"], allow_fail: true)

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
    sh!("ip", ["link", "del", tap_name], allow_fail: true)
    :ok
  end

  defp detect_outbound_iface_linux! do
    {out, 0} = System.cmd("sh", ["-c", "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'"])
    String.trim(out)
  end

  defp link_exists_linux?(name) do
    case System.cmd("ip", ["link", "show", name], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  # ========================================================================
  # macOS Implementation (for Cloud Hypervisor)
  # ========================================================================

  defp ensure_host_network_macos! do
    # On macOS, Cloud Hypervisor handles most networking internally
    # We just need to ensure IP forwarding is enabled

    sh!("sysctl", ["-w", "net.inet.ip.forwarding=1"])

    Logger.info("macOS host network configured (Cloud Hypervisor handles TAP interfaces)")
    :ok
  end

  defp create_tap_macos!(tap_name, :cloud_hypervisor) do
    # Cloud Hypervisor on macOS creates TAP interfaces automatically
    # We don't need to create them manually
    Logger.debug("TAP #{tap_name} will be created by Cloud Hypervisor on macOS")
    :ok
  end

  defp create_tap_macos!(_tap_name, :firecracker) do
    raise """
    Firecracker is not supported on macOS ARM64.
    Use Cloud Hypervisor instead (default on macOS).
    """
  end

  defp delete_tap_macos(tap_name, :cloud_hypervisor) do
    # Cloud Hypervisor cleans up its own TAP interfaces
    Logger.debug("TAP #{tap_name} cleanup handled by Cloud Hypervisor on macOS")
    :ok
  end

  defp delete_tap_macos(_tap_name, :firecracker) do
    # No-op since Firecracker isn't supported on macOS
    :ok
  end

  # ========================================================================
  # Shared helpers
  # ========================================================================

  defp subnet_cidr do
    # Assumes bridge_cidr like 172.16.0.1/24
    # Converts to 172.16.0.0/24
    [ip, mask] = String.split(Config.bridge_cidr(), "/", parts: 2)
    base = ip |> String.split(".") |> List.replace_at(3, "0") |> Enum.join(".")
    "#{base}/#{mask}"
  end

  defp sh!(cmd, args, opts \\ []) do
    allow_fail = Keyword.get(opts, :allow_fail, false)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} ->
        out

      {out, code} ->
        if allow_fail do
          out
        else
          raise "Command failed: #{cmd} #{Enum.join(args, " ")} (exit #{code})\n#{out}"
        end
    end
  end
end
