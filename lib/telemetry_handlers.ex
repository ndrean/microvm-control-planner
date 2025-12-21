defmodule FcExCp.TelemetryHandlers do
  @moduledoc """
  Example telemetry handlers for debugging and logging telemetry events.

  These handlers can be attached during development for debugging purposes.
  Use in iex or add to Application.start/2 for development/test environments.
  """

  require Logger
  alias FcExCp.{Metrics, PoolManager}

  @doc """
  Attach all debug handlers to print telemetry events to console.

  Usage in iex:
    FcExCp.TelemetryHandlers.attach_debug_handlers()
  """
  def attach_debug_handlers do
    Logger.info("Attaching telemetry debug handlers...")

    :telemetry.attach_many(
      "debug_vm_events",
      [
        [:fc_ex_cp, :vm, :boot],
        [:fc_ex_cp, :vm, :boot_failed],
        [:fc_ex_cp, :vm, :shutdown]
      ],
      &handle_vm_events/4,
      nil
    )

    :telemetry.attach_many(
      "debug_scheduler_events",
      [
        [:fc_ex_cp, :scheduler, :tick],
        [:fc_ex_cp, :scheduler, :acquire],
        [:fc_ex_cp, :scheduler, :release]
      ],
      &handle_scheduler_events/4,
      nil
    )

    :telemetry.attach_many(
      "debug_firecracker_events",
      [
        [:fc_ex_cp, :firecracker, :vcpu_exits],
        [:fc_ex_cp, :firecracker, :vcpu_time],
        [:fc_ex_cp, :firecracker, :memory]
      ],
      &handle_firecracker_events/4,
      nil
    )

    :telemetry.attach_many(
      "debug_host_events",
      [
        [:fc_ex_cp, :host, :resources],
        [:fc_ex_cp, :host, :memory_pressure],
        [:fc_ex_cp, :host, :cpu_contention]
      ],
      &handle_host_events/4,
      nil
    )

    :telemetry.attach_many(
      "debug_runtime_events",
      [
        [:fc_ex_cp, :runtime, :snapshot],
        [:fc_ex_cp, :runtime, :gc]
      ],
      &handle_runtime_events/4,
      nil
    )

    Logger.info("Debug handlers attached successfully")
  end

  @doc """
  Detach all debug handlers.
  """
  def detach_debug_handlers do
    :telemetry.detach("debug_vm_events")
    :telemetry.detach("debug_scheduler_events")
    :telemetry.detach("debug_firecracker_events")
    :telemetry.detach("debug_host_events")
    :telemetry.detach("debug_runtime_events")
    Logger.info("Debug handlers detached")
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  defp handle_vm_events([:fc_ex_cp, :vm, :boot], measurements, metadata, _config) do
    Logger.info(
      "VM BOOT: id=#{metadata.vm_id} duration=#{measurements.duration_ms}ms tenant=#{metadata.tenant}"
    )
  end

  defp handle_vm_events([:fc_ex_cp, :vm, :boot_failed], measurements, metadata, _config) do
    Logger.error(
      "VM BOOT FAILED: id=#{metadata.vm_id} error=#{measurements.error} tenant=#{metadata.tenant}"
    )
  end

  defp handle_vm_events([:fc_ex_cp, :vm, :shutdown], _measurements, metadata, _config) do
    Logger.info("VM SHUTDOWN: id=#{metadata.vm_id} reason=#{metadata.reason}")
  end

  defp handle_scheduler_events([:fc_ex_cp, :scheduler, :tick], measurements, _metadata, _config) do
    Logger.debug(
      "SCHEDULER TICK: warm=#{measurements.warm} busy=#{measurements.busy} total=#{measurements.total}"
    )
  end

  defp handle_scheduler_events([:fc_ex_cp, :scheduler, :acquire], measurements, metadata, _config) do
    Logger.info(
      "VM ACQUIRED: id=#{metadata.vm_id} duration=#{measurements.duration_ms}ms from_warm=#{metadata.from_warm_pool}"
    )
  end

  defp handle_scheduler_events([:fc_ex_cp, :scheduler, :release], measurements, metadata, _config) do
    Logger.info(
      "VM RELEASED: id=#{metadata.vm_id} reused=#{measurements.reused} returned_to_warm=#{metadata.returned_to_warm}"
    )
  end

  defp handle_firecracker_events(
         [:fc_ex_cp, :firecracker, :vcpu_exits],
         measurements,
         metadata,
         _config
       ) do
    Logger.debug("FIRECRACKER vCPU EXITS: id=#{metadata.vm_id} exits=#{measurements.exits}")
  end

  defp handle_firecracker_events(
         [:fc_ex_cp, :firecracker, :vcpu_time],
         measurements,
         metadata,
         _config
       ) do
    Logger.debug("FIRECRACKER vCPU TIME: id=#{metadata.vm_id} time_ms=#{measurements.time_ms}")
  end

  defp handle_firecracker_events(
         [:fc_ex_cp, :firecracker, :memory],
         measurements,
         metadata,
         _config
       ) do
    Logger.debug(
      "FIRECRACKER MEMORY: id=#{metadata.vm_id} allocated=#{measurements.allocated} actual=#{measurements.actual}"
    )
  end

  defp handle_host_events([:fc_ex_cp, :host, :resources], measurements, _metadata, _config) do
    Logger.debug(
      "HOST RESOURCES: cpu=#{measurements.cpu_usage}% mem_avail=#{div(measurements.memory_available, 1_000_000_000)}GB mem_used=#{div(measurements.memory_used, 1_000_000_000)}GB"
    )
  end

  defp handle_host_events([:fc_ex_cp, :host, :memory_pressure], measurements, metadata, _config) do
    Logger.warning(
      "HOST MEMORY PRESSURE: level=#{metadata.level} usage=#{measurements.usage_percent}%"
    )
  end

  defp handle_host_events([:fc_ex_cp, :host, :cpu_contention], measurements, _metadata, _config) do
    Logger.warning("HOST CPU CONTENTION: usage=#{measurements.usage_percent}%")
  end

  defp handle_runtime_events([:fc_ex_cp, :runtime, :snapshot], measurements, _metadata, _config) do
    Logger.debug(
      "RUNTIME SNAPSHOT: processes=#{measurements.process_count} memory=#{div(measurements.total_memory, 1_000_000)}MB run_queue=#{measurements.run_queue}"
    )
  end

  defp handle_runtime_events([:fc_ex_cp, :runtime, :gc], measurements, metadata, _config) do
    Logger.debug(
      "RUNTIME GC: gen=#{metadata.generation} collections=#{measurements.collections} words_reclaimed=#{measurements.words_reclaimed}"
    )
  end

  # ============================================================================
  # Metrics Extraction Helpers
  # ============================================================================

  @doc """
  Get current scheduler statistics from emitted metrics.

  Requires a registered handler collecting scheduler tick events.
  """
  def get_scheduler_stats do
    # This would need a separate handler to collect and store state
    # For now, call Manager directly:
    PoolManager.stats()
  end

  @doc """
  Get current host metrics from emitted metrics.
  """
  def get_host_metrics do
    Metrics.host_metrics()
  end

  @doc """
  Get current runtime metrics from emitted metrics.
  """
  def get_runtime_metrics do
    Metrics.snap()
  end
end
