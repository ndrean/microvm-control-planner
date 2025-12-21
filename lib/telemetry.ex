defmodule FcExCp.TelemetryPoller do
  @moduledoc """
  Telemetry polling supervisor for periodic metric collection.

  Collects metrics on intervals for:
  - Runtime metrics (memory, GC, processes)
  - Scheduler state (pool status)
  - Host resources (CPU, memory)
  - Firecracker metrics (via metrics file)
  """
  require Logger
  alias FcExCp.{Metrics, PoolManager, TelemetryEvents}

  # def start_link(_) do
  #   measurements = [
  #     # Runtime metrics polling
  #     {__MODULE__, :collect_runtime_metrics, []},
  #     # Scheduler state polling
  #     {__MODULE__, :collect_scheduler_state, []},
  #     # Host resource polling
  #     {__MODULE__, :collect_host_metrics, []},
  #     # Firecracker metrics polling (if available)
  #     {__MODULE__, :collect_firecracker_metrics, []}
  #   ]

  #   :telemetry_poller.start_link(
  #     measurements: measurements,
  #     period: 5_000
  #   )
  # end

  # ============================================================================
  # BEAM Runtime Metrics Collection
  # ============================================================================

  def collect_runtime_metrics do
    runtime_stats = Metrics.snap()
    TelemetryEvents.beam_runtime_snapshot(runtime_stats)

    # Also emit individual runtime metrics
    :telemetry.execute(
      [:fc_ex_cp, :runtime],
      %{
        run_queue: runtime_stats.run_queue,
        total_memory: runtime_stats.total_memory,
        processes_memory: runtime_stats.processes_memory,
        system_memory: runtime_stats.system_memory,
        process_count: runtime_stats.process_count
      },
      %{}
    )
  end

  # ============================================================================
  # Scheduler State Collection
  # ============================================================================

  def collect_scheduler_state do
    try do
      {:ok, stats} = PoolManager.stats()
      TelemetryEvents.scheduler_tick(stats)

      # Also emit individual gauge metrics
      :telemetry.execute(
        [:fc_ex_cp, :scheduler],
        %{
          warm: stats.warm,
          busy: stats.busy,
          total: stats.total
        },
        %{}
      )
    rescue
      e -> Logger.debug("Failed to collect scheduler state: #{inspect(e)}")
    end
  end

  # ============================================================================
  # Host Resource Metrics Collection
  # ============================================================================

  def collect_host_metrics do
    case Metrics.host_metrics() do
      %{} = host_stats ->
        TelemetryEvents.host_resources(host_stats)

        # Emit individual host metrics
        {load1, load5, load15} = host_stats.load_avg

        :telemetry.execute(
          [:fc_ex_cp, :host],
          %{
            cpu_usage: host_stats.cpu_usage,
            memory_available: host_stats.memory_available,
            memory_used: host_stats.memory_used,
            load_avg_1: load1,
            load_avg_5: load5,
            load_avg_15: load15
          },
          %{}
        )

      nil ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Failed to collect host metrics: #{inspect(e)}")
  end

  # ============================================================================
  # Firecracker Metrics Collection
  # ============================================================================

  def collect_firecracker_metrics do
    # Poll all active VMs
    Registry.select(FcExCp.Registry, [
      {{{:vm, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
    |> Enum.each(&collect_vm_metrics/1)
  rescue
    e ->
      Logger.debug("Failed to collect Firecracker metrics: #{inspect(e)}")
  end

  defp collect_vm_metrics(vm_id) do
    case safe_vm_info(vm_id) do
      {:ok, info} ->
        emit_unified_vm_metrics(vm_id, info)

      _ ->
        :ok
    end
  end

  defp safe_vm_info(vm_id) do
    try do
      # Use a short timeout to avoid blocking poller
      case GenServer.call(FcExCp.VM.via(vm_id), :info, 1000) do
        info when is_map(info) -> {:ok, info}
        _ -> :error
      end
    catch
      :exit, _ -> :error
      _, _ -> :error
    end
  end

  defp emit_unified_vm_metrics(vm_id, info) do
    # 1. Firecracker Metrics File
    fc_metrics = Metrics.read_fc_metrics(info.metrics_path) || %{}

    # Extract vcpu exits (sum of all vcpus)
    vcpu_exits =
      case fc_metrics["vcpu_statistics"] do
        stats when is_list(stats) ->
          Enum.reduce(stats, 0, fn vcpu, acc -> acc + (vcpu["exit_count"] || 0) end)

        _ ->
          0
      end

    # 2. Proc Stats (Host PID)
    proc_stats = Metrics.proc_stats(info.pid) || %{rss_bytes: 0, cpu_ticks: 0}

    # 3. Cgroup Stats
    # Dynamically resolve cgroup path from PID
    cgroup_path = Metrics.get_cgroup_path(info.pid)
    cgroup_stats = Metrics.cgroup_stats(cgroup_path) || %{memory_bytes: 0, cpu_usage_usec: 0}

    # 4. Guest CPU
    # Using cgroup cpu usage as the most accurate measure of guest CPU consumption
    guest_cpu = cgroup_stats.cpu_usage_usec

    # Emit Unified Event
    TelemetryEvents.vm_resources(vm_id, %{
      guest_cpu: guest_cpu,
      fc_vcpu_exits: vcpu_exits,
      host_rss: proc_stats.rss_bytes,
      cgroup_mem: cgroup_stats.memory_bytes
    })
  end
end
