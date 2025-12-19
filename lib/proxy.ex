defmodule FcExCp.Proxy do
  @moduledoc """
  for Caddy/Envoy/HAProxy
  """
  require Logger
  alias FcExCp.Config

  # Called when a VM becomes ready
  def register(_tenant, _ip, _port) do
    case Config.proxy_mode() do
      :none ->
        :ok

      :caddy ->
        # implement Caddy admin API changes here.
        # Keeping it as stub because the exact JSON depends on config strategy.
        Logger.info("Proxy register stub (caddy): tenant=#{inspect(_tenant)} -> #{_ip}:#{_port}")
        :ok
    end
  end

  def deregister(_tenant) do
    case Config.proxy_mode() do
      :none ->
        :ok

      :caddy ->
        Logger.info("Proxy deregister stub (caddy): tenant=#{inspect(_tenant)}")
        :ok
    end
  end
end
