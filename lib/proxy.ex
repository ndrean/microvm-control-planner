defmodule FcExCp.Proxy do
  @moduledoc """
  Load balancer integration for Caddy/Envoy/HAProxy.

  ## Discovery and Warm VMs

  **Critical:** Warm VMs (tenant: :warm) are NEVER registered with the proxy.
  This prevents load balancers from discovering and routing traffic to VMs
  that are pre-booted but not yet assigned to a service.

  ### Flow:

  1. VM boots with `tenant: :warm` → **NOT registered** (invisible to LB)
  2. VM assigned to job → `update_tenant("web-app-1")` → **Registered** (visible to LB)
  3. VM terminated → **Deregistered** (removed from LB pool)

  ### Why?

  For a Phoenix LiveView app:
  - Warm VM: 172.16.0.2:4000 listening but NOT in LB pool
  - Running VM: 172.16.0.2:4000 registered → receives traffic

  Jobs don't have warm state - they're either running (registered) or not.
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
        # Logger.info("Proxy register stub (caddy): tenant=#{inspect(tenant)} -> #{_ip}:#{_port}")
        :ok
    end
  end

  def deregister(_tenant) do
    case Config.proxy_mode() do
      :none ->
        :ok

      :caddy ->
        # Logger.info("Proxy deregister stub (caddy): tenant=#{inspect(_tenant)}")
        :ok
    end
  end
end
