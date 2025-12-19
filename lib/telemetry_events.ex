defmodule FcExCp.TelemetryEvents do
  @moduledoc """
  Helper functions for emitting telemetry events throughout the application.

  This module centralizes all telemetry event emissions for:
  - VM lifecycle events (boot, shutdown, acquire)
  - Scheduler events (pool state changes)
  - Firecracker events (vCPU metrics, memory stats)
  - Host resource events
  """

  require Logger

  # ============================================================================
  # VM Lifecycle Events
  # ============================================================================

  @doc """
  Emit a VM boot event with duration and metadata.

  Usage:
    vm_booted(vm_id, duration_ms, %{tenant: tenant})
  """
  def vm_booted(vm_id, duration_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :vm, :boot],
      %{duration_ms: duration_ms},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc "Emit VM boot failure event"
  def vm_boot_failed(vm_id, error_reason, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :vm, :boot_failed],
      %{error: inspect(error_reason)},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc "Emit VM shutdown event"
  def vm_shutdown(vm_id, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :vm, :shutdown],
      %{},
      Map.merge(%{vm_id: vm_id, reason: inspect(reason)}, metadata)
    )
  end

  @doc "Emit VM acquired from pool event"
  def vm_acquired(vm_id, acquire_duration_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :scheduler, :acquire],
      %{duration_ms: acquire_duration_ms},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc "Emit VM released back to pool event"
  def vm_released(vm_id, reused, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :scheduler, :release],
      %{reused: reused},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  # ============================================================================
  # Scheduler / Pool Events
  # ============================================================================

  @doc """
  Emit scheduler tick with pool state snapshot.

  Usage:
    scheduler_tick(%{warm: 3, busy: 2, total: 5})
  """
  def scheduler_tick(state) do
    :telemetry.execute(
      [:fc_ex_cp, :scheduler, :tick],
      %{
        warm: state.warm,
        busy: state.busy,
        total: state.total
      },
      %{}
    )
  end

  @doc "Emit event when warm pool target is changed"
  def scheduler_target_changed(old_target, new_target) do
    :telemetry.execute(
      [:fc_ex_cp, :scheduler, :target_changed],
      %{old_target: old_target, new_target: new_target},
      %{}
    )
  end

  # ============================================================================
  # Firecracker Process Events (per VM)
  # ============================================================================

  @doc """
  Emit Firecracker vCPU exit event.

  Usage:
    firecracker_vcpu_exits(vm_id, 42, %{exit_type: :halt})
  """
  def firecracker_vcpu_exits(vm_id, exit_count, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :firecracker, :vcpu_exits],
      %{exits: exit_count},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc """
  Emit Firecracker vCPU time event (CPU time spent in VM).

  Usage:
    firecracker_vcpu_time(vm_id, 5000)  # 5000ms
  """
  def firecracker_vcpu_time(vm_id, time_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :firecracker, :vcpu_time],
      %{time_ms: time_ms},
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc """
  Emit Firecracker memory event (VM memory statistics).

  Usage:
    firecracker_memory(vm_id, %{allocated: 256_000_000, actual: 245_000_000})
  """
  def firecracker_memory(vm_id, mem_stats, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :firecracker, :memory],
      mem_stats,
      Map.merge(%{vm_id: vm_id}, metadata)
    )
  end

  @doc """
  Emit Firecracker API call event.

  Usage:
    firecracker_api_call(vm_id, :put, "/drives/root", 125)
  """
  def firecracker_api_call(vm_id, method, path, duration_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :firecracker, :api_call],
      %{duration_ms: duration_ms},
      Map.merge(%{vm_id: vm_id, method: method, path: path}, metadata)
    )
  end

  @doc """
  Emit unified VM resource metrics (guest CPU, vCPU exits, host RSS, cgroup memory).
  """
  def vm_resources(vm_id, metrics) do
    :telemetry.execute(
      [:fc_ex_cp, :vm, :resources],
      metrics,
      %{vm_id: vm_id}
    )
  end

  # ============================================================================
  # Host Resource Events
  # ============================================================================

  @doc """
  Emit host resource snapshot event.

  Usage:
    host_resources(%{
      cpu_usage: 45.2,
      memory_available: 1_000_000_000,
      memory_used: 4_000_000_000,
      load_avg: {2.5, 2.1, 1.9}
    })
  """
  def host_resources(metrics) do
    {load1, load5, load15} = Map.get(metrics, :load_avg, {0, 0, 0})

    :telemetry.execute(
      [:fc_ex_cp, :host, :resources],
      %{
        cpu_usage: Map.get(metrics, :cpu_usage, 0),
        memory_available: Map.get(metrics, :memory_available, 0),
        memory_used: Map.get(metrics, :memory_used, 0),
        load_avg_1: load1,
        load_avg_5: load5,
        load_avg_15: load15
      },
      %{}
    )
  end

  @doc """
  Emit host memory contention event (when available memory is low).

  Usage:
    host_memory_pressure(:critical)  # or :warning, :normal
  """
  def host_memory_pressure(level, available_bytes, total_bytes, metadata \\ %{}) do
    usage_percent = round((1 - available_bytes / total_bytes) * 100)

    :telemetry.execute(
      [:fc_ex_cp, :host, :memory_pressure],
      %{usage_percent: usage_percent},
      Map.merge(%{level: level}, metadata)
    )
  end

  @doc """
  Emit host CPU contention event.

  Usage:
    host_cpu_contention(75.5)
  """
  def host_cpu_contention(cpu_percent, metadata \\ %{}) do
    :telemetry.execute(
      [:fc_ex_cp, :host, :cpu_contention],
      %{usage_percent: cpu_percent},
      metadata
    )
  end

  # ============================================================================
  # BEAM Runtime Events
  # ============================================================================

  @doc """
  Emit BEAM runtime snapshot event.

  Usage:
    beam_runtime_snapshot(%{
      run_queue: 2,
      total_memory: 50_000_000,
      processes_memory: 30_000_000,
      system_memory: 20_000_000,
      process_count: 256
    })
  """
  def beam_runtime_snapshot(runtime_stats) do
    :telemetry.execute(
      [:fc_ex_cp, :runtime, :snapshot],
      %{
        run_queue: Map.get(runtime_stats, :run_queue, 0),
        total_memory: Map.get(runtime_stats, :total_memory, 0),
        processes_memory: Map.get(runtime_stats, :processes_memory, 0),
        system_memory: Map.get(runtime_stats, :system_memory, 0),
        process_count: Map.get(runtime_stats, :process_count, 0)
      },
      %{}
    )
  end

  @doc """
  Emit BEAM garbage collection event.

  Usage:
    beam_gc_stats(generation, collections, words_reclaimed)
  """
  def beam_gc_stats(generation, collections, words_reclaimed) do
    :telemetry.execute(
      [:fc_ex_cp, :runtime, :gc],
      %{
        collections: collections,
        words_reclaimed: words_reclaimed
      },
      %{generation: generation}
    )
  end
end
