defmodule FcExCp.Firecracker do
  @callback boot(vm_id :: String.t(), tenant :: String.t() | nil, spec :: map()) ::
              :ok | {:error, term()}

  @callback warm_up(vm_id :: String.t(), spec :: map()) :: :ok | {:error, term()}

  @callback stop(vm_id :: String.t()) :: :ok
end

defmodule FcExCp.Firecracker.Mock do
  @behaviour FcExCp.Firecracker

  require Logger

  @impl true
  def boot(vm_id, tenant, spec) do
    Logger.info(
      "[MOCK] boot VM #{vm_id} tenant=#{inspect(tenant)} lifecycle=#{spec["lifecycle"]}"
    )

    # Pretend boot time
    Process.sleep(200)
    :ok
  end

  @impl true
  def warm_up(vm_id, spec) do
    Logger.info("[MOCK] warm_up VM #{vm_id} lifecycle=#{spec["lifecycle"]}")

    # Simulate expensive warm-up based on lifecycle
    case spec["lifecycle"] do
      "service" ->
        # Long-running service: dump DB, start CDC, health checks
        Logger.info("[MOCK]   - Dumping shared Postgres to local DB...")
        Process.sleep(2000)
        Logger.info("[MOCK]   - Subscribing to CDC stream...")
        Process.sleep(500)
        Logger.info("[MOCK]   - Starting application services...")
        Process.sleep(300)

      "job" ->
        # Job: pre-load dependencies, warm up runtime
        Logger.info("[MOCK]   - Pre-loading job dependencies...")
        Process.sleep(500)

      "daemon" ->
        # Daemon: similar to service but lighter
        Logger.info("[MOCK]   - Starting daemon processes...")
        Process.sleep(800)

      _ ->
        # Default: minimal warm-up
        Process.sleep(100)
    end

    Logger.info("[MOCK] ✓ VM #{vm_id} is warm and ready!")
    :ok
  end

  @impl true
  def stop(vm_id) do
    Logger.info("[MOCK] stop VM #{vm_id}")
    :ok
  end
end
