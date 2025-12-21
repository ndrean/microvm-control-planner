defmodule FcExCp.NetLinux do
  @moduledoc """
  Host networking
  This is the “real TAP bridge + NAT” part.
  It uses ip + iptables.
  TODO: For production use nftables
  """
  require Logger
  alias FcExCp.Config

  def ensure_host_network! do
    bridge = Config.bridge()
    cidr = Config.bridge_cidr()
    out = Config.outbound_iface() || detect_outbound_iface!()

    # bridge br0
    unless link_exists?(bridge) do
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

  def create_tap!(tap_name) do
    bridge = Config.bridge()

    sh!("ip", ["tuntap", "add", tap_name, "mode", "tap"])
    sh!("ip", ["link", "set", tap_name, "master", bridge])
    sh!("ip", ["link", "set", tap_name, "up"])
    :ok
  end

  def delete_tap(tap_name) do
    _ = sh!("ip", ["link", "del", tap_name], allow_fail: true)
    :ok
  end

  def detect_outbound_iface! do
    {out, 0} =
      System.cmd("sh", [
        "-lc",
        "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}'"
      ])

    String.trim(out)
  end

  defp subnet_cidr do
    # assumes bridge_cidr like 172.16.0.1/24
    [ip, mask] = String.split(Config.bridge_cidr(), "/", parts: 2)
    # Turn 172.16.0.1 -> 172.16.0.0/24
    base = ip |> String.split(".") |> List.replace_at(3, "0") |> Enum.join(".")
    "#{base}/#{mask}"
  end

  defp link_exists?(name) do
    case System.cmd("ip", ["link", "show", name], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
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
          raise "Command failed: #{cmd} #{Enum.join(args, " ")} (#{code})\n#{out}"
        end
    end
  end
end
