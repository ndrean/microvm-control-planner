defmodule FcExCp.Config do
  @moduledoc false

  def kernel_path(), do: env!(:kernel_path)
  def rootfs_path(), do: env!(:rootfs_path)

  # Network
  def bridge(), do: env(:bridge, "br0")
  def bridge_cidr(), do: env(:bridge_cidr, "172.16.0.1/24")
  # last octet allocated per VM
  def subnet_prefix(), do: env(:subnet_prefix, "172.16.0.")
  # auto-detect if nil
  def outbound_iface(), do: env(:outbound_iface, nil)

  # Phoenix inside VM
  def guest_port(), do: env(:guest_port, 4000)

  # Pool settings
  def warm_target(), do: env(:warm_target, 1)
  def max_vms(), do: env(:max_vms, 50)

  # HTTP API
  def listen_ip(), do: env(:listen_ip, {0, 0, 0, 0})
  def listen_port(), do: env(:listen_port, 8088)

  # Optional: reverse proxy integration
  # :none | :caddy
  def proxy_mode(), do: env(:proxy_mode, :none)
  def caddy_admin_url(), do: env(:caddy_admin_url, "http://127.0.0.1:2019")

  defp env!(key) do
    Application.fetch_env!(:fc_ex_cp, key)
  end

  defp env(key, default) do
    Application.get_env(:fc_ex_cp, key, default)
  end
end
