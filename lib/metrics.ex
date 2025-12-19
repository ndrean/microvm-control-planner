defmodule FcExCp.Metrics do
  @moduledoc """
  Prometheus Metrics (for Grafana dashboards)

  This module defines all telemetry metrics for:
  - control plan health
  - host health
  - guest reousrce uage
  - VM lifecycle metrics (boot, shutdown)
  - Scheduler metrics (warm pool, busy VMs)
  - BEAM runtime metrics (memory, GC, processes)
  - Firecracker process metrics (vCPU exits, vcpu time)
  - Host resource metrics (CPU, memory contention)

  The aggregation combines in a single `vm_resources` event
  to see if the VM is slow because of I/O or CPU thorttled (high cgroup usage)
  """
  import Telemetry.Metrics
  require Logger

  def metrics do
    [
      # VM Lifecycle Metrics
      # how fast to boot?
      last_value("fc_ex_cp.vm.boot.duration_ms", unit: :millisecond),
      counter("fc_ex_cp.vm.boot.count"),
      counter("fc_ex_cp.vm.shutdown.count"),
      last_value("fc_ex_cp.vm.active.count"),

      # Scheduler/Pool Metrics
      last_value("fc_ex_cp.scheduler.warm.count"),
      last_value("fc_ex_cp.scheduler.busy.count"),
      last_value("fc_ex_cp.scheduler.total.count"),
      sum("fc_ex_cp.scheduler.acquire.duration_ms", unit: :millisecond),

      # BEAM Runtime Metrics
      last_value("fc_ex_cp.runtime.run_queue.length"),
      last_value("fc_ex_cp.runtime.memory.total", unit: :byte),
      last_value("fc_ex_cp.runtime.memory.processes", unit: :byte),
      last_value("fc_ex_cp.runtime.memory.system", unit: :byte),
      last_value("fc_ex_cp.runtime.processes.count"),
      counter("fc_ex_cp.runtime.gc.collections"),
      last_value("fc_ex_cp.runtime.gc.words_reclaimed"),

      # Firecracker Metrics (per VM)
      counter("fc_ex_cp.firecracker.vcpu.exits"),
      last_value("fc_ex_cp.firecracker.vcpu.time_ms", unit: :millisecond),
      counter("fc_ex_cp.firecracker.memory.allocations"),
      last_value("fc_ex_cp.firecracker.memory.size", unit: :byte),

      # Host Resource Metrics
      last_value("fc_ex_cp.host.cpu.usage_percent"),
      last_value("fc_ex_cp.host.memory.available", unit: :byte),
      last_value("fc_ex_cp.host.memory.used", unit: :byte),
      last_value("fc_ex_cp.host.load.avg1"),
      last_value("fc_ex_cp.host.load.avg5"),
      last_value("fc_ex_cp.host.load.avg15")
    ]
  end

  # Collect Firecracker metrics via --metrics-path /run/firecracker/fc-123.metrics
  def read_fc_metrics(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json) do
      data
    else
      {:error, reason} ->
        Logger.warning("Failed to read Firecracker metrics from #{path}: #{inspect(reason)}")
        nil
    end
  end

  # Snapshot current BEAM runtime metrics
  def snap() do
    %{
      run_queue: :erlang.statistics(:run_queue),
      total_memory: :erlang.memory(:total),
      processes_memory: :erlang.memory(:processes),
      system_memory: :erlang.memory(:system),
      process_count: :erlang.system_info(:process_count)
    }
  end

  # Get host metrics (CPU, memory, load)
  def host_metrics do
    try do
      # Check if cpu_sup is responding
      _ = :cpu_sup.nprocs()

      %{
        cpu_usage: get_cpu_usage(),
        memory_available: get_available_memory(),
        memory_used: get_used_memory(),
        load_avg: get_load_average()
      }
    rescue
      _ ->
        Logger.debug("os_mon not available, skipping host metrics")
        nil
    end
  end

  def proc_stats(pid) do
    try do
      stat = File.read!("/proc/#{pid}/stat") |> String.split()
      rss_pages = String.to_integer(Enum.at(stat, 23))
      utime = String.to_integer(Enum.at(stat, 13))
      stime = String.to_integer(Enum.at(stat, 14))

      %{
        rss_bytes: rss_pages * 4096,
        cpu_ticks: utime + stime
      }
    rescue
      _ -> nil
    end
  end

  def get_cgroup_path(pid) do
    try do
      File.read!("/proc/#{pid}/cgroup")
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, ":") do
          # cgroup v2
          ["0", "", path] -> path
          # cgroup v1 memory
          [_, "memory", path] -> path
          _ -> nil
        end
      end)
      |> case do
        nil -> nil
        "/" -> "/sys/fs/cgroup"
        path -> "/sys/fs/cgroup#{path}"
      end
    rescue
      _ -> nil
    end
  end

  def cgroup_stats(path) do
    try do
      mem = File.read!(Path.join(path, "memory.current")) |> String.trim() |> String.to_integer()
      cpu_stat = File.read!(Path.join(path, "cpu.stat"))

      # Parse usage_usec from cpu.stat
      cpu_usage =
        cpu_stat
        |> String.split("\n")
        |> Enum.find_value(0, fn line ->
          case String.split(line) do
            ["usage_usec", val] -> String.to_integer(val)
            _ -> nil
          end
        end)

      %{memory_bytes: mem, cpu_usage_usec: cpu_usage}
    rescue
      _ -> nil
    end
  end

  defp get_cpu_usage do
    :cpu_sup.util()
  rescue
    _ -> 0
  end

  defp get_available_memory do
    data = :memsup.get_system_memory_data()
    Keyword.get(data, :free_memory, 0)
  rescue
    _ -> 0
  end

  defp get_used_memory do
    data = :memsup.get_system_memory_data()
    total = Keyword.get(data, :system_total_memory, 0)
    free = Keyword.get(data, :free_memory, 0)
    total - free
  rescue
    _ -> 0
  end

  defp get_load_average do
    l1 = :cpu_sup.avg1() / 256
    l5 = :cpu_sup.avg5() / 256
    l15 = :cpu_sup.avg15() / 256
    {l1, l5, l15}
  rescue
    _ -> {0, 0, 0}
  end
end

# [
#   counter("http.request.count"),
#   sum("http.request.payload_size", unit: :byte),
#   sum("websocket.connection.count", reporter_options: [prometheus_type: :gauge]),
#   last_value("vm.memory.total", unit: :byte)
# ]
