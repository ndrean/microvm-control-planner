defmodule FcExCp.Manager do
  @moduledoc """
  Pool Manager
  - Keeps a warm pool (+ 1 strategy)
  - `acquire/1` returns a ready VM (booting if needed)
  - `release/1` returns VM to warm pool or reaps

  Track warm and busy allow to optimize cold start times
  """
  use GenServer
  require Logger
  alias FcExCp.{Config, VM, VMSup, TelemetryEvents}

  @tick_ms 2_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def acquire(tenant \\ nil), do: GenServer.call(__MODULE__, {:acquire, tenant}, 60_000)
  def release(vm_id), do: GenServer.cast(__MODULE__, {:release, vm_id})
  def lookup(vm_id), do: GenServer.call(__MODULE__, {:lookup, vm_id})
  def stats(), do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_) do
    state = %{
      # vm_id
      warm: MapSet.new(),
      # vm_id => %{tenant, since}
      busy: %{},
      # vm_id => pid
      pid: %{}
    }

    send(self(), :ensure_warm)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, st) do
    {:reply,
     %{
       warm: MapSet.size(st.warm),
       busy: map_size(st.busy),
       total: map_size(st.pid)
     }, st}
  end

  @impl true
  def handle_call({:lookup, vm_id}, _from, st) do
    case st.pid[vm_id] do
      nil ->
        {:reply, :error, st}

      _pid ->
        {:ok, info} = safe_info(vm_id)
        {:reply, {:ok, info}, st}
    end
  end

  @impl true
  def handle_call({:acquire, tenant}, _from, st) do
    acquire_start = System.monotonic_time(:millisecond)

    case MapSet.to_list(st.warm) do
      [vm_id | _] ->
        st = st |> warm_take(vm_id) |> mark_busy(vm_id, tenant)
        {:ok, info} = safe_info(vm_id)

        # Emit telemetry: VM acquired from warm pool
        duration_ms = System.monotonic_time(:millisecond) - acquire_start

        TelemetryEvents.vm_acquired(vm_id, duration_ms, %{
          tenant: inspect(tenant),
          from_warm_pool: true
        })

        {:reply, {:ok, info}, st}

      [] ->
        with {:ok, vm_id, st} <- spawn_and_boot(st, tenant) do
          {:ok, info} = safe_info(vm_id)

          # Emit telemetry: VM acquired after boot
          duration_ms = System.monotonic_time(:millisecond) - acquire_start

          TelemetryEvents.vm_acquired(vm_id, duration_ms, %{
            tenant: inspect(tenant),
            from_warm_pool: false,
            boot_required: true
          })

          {:reply, {:ok, info}, st}
        else
          {:error, reason, st} ->
            {:reply, {:error, reason}, st}
        end
    end
  end

  @impl true
  def handle_cast({:release, vm_id}, st) do
    reused = MapSet.size(st.warm) < Config.warm_target()

    st =
      st
      |> unmark_busy(vm_id)
      |> maybe_keep_warm(vm_id)

    # Emit telemetry: VM released back to pool (or reaped)
    TelemetryEvents.vm_released(vm_id, reused, %{
      returned_to_warm: reused
    })

    send(self(), :ensure_warm)
    {:noreply, st}
  end

  @impl true
  def handle_info(:ensure_warm, st) do
    target = Config.warm_target()
    warm_count = MapSet.size(st.warm)
    total = map_size(st.pid)

    needed = max(target - warm_count, 0)
    capacity = max(Config.max_vms() - total, 0)
    to_spawn = min(needed, capacity)

    st =
      Enum.reduce(1..to_spawn, st, fn _, acc ->
        case spawn_and_boot(acc, nil) do
          {:ok, vm_id, acc} ->
            acc |> warm_put(vm_id)

          {:error, reason, acc} ->
            Logger.error("warm spawn failed: #{inspect(reason)}")
            acc
        end
      end)

    {:noreply, st}
  end

  @impl true
  def handle_info(:tick, st) do
    # Emit scheduler tick with current pool state
    stats = %{
      warm: MapSet.size(st.warm),
      busy: map_size(st.busy),
      total: map_size(st.pid)
    }

    TelemetryEvents.scheduler_tick(stats)

    # Here you can implement:
    # - reap too many warm VMs
    # - scale based on metrics
    # - watchdog busy leases
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, st}
  end

  # --- internals

  defp spawn_and_boot(st, tenant) do
    id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    spec = {VM, [id: id, tenant: tenant]}

    case DynamicSupervisor.start_child(VMSup, spec) do
      {:ok, pid} ->
        st = put_in(st.pid[id], pid)

        case VM.boot(id) do
          {:ok, _info} ->
            st = if tenant, do: mark_busy(st, id, tenant), else: st
            {:ok, id, st}

          {:error, reason} ->
            DynamicSupervisor.terminate_child(VMSup, pid)
            st = update_in(st.pid, &Map.delete(&1, id))
            {:error, reason, st}
        end

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  defp safe_info(vm_id) do
    info = VM.info(vm_id)
    {:ok, info}
  rescue
    _ -> {:error, :no_vm}
  end

  defp mark_busy(st, vm_id, tenant) do
    put_in(st.busy[vm_id], %{tenant: tenant, since: System.monotonic_time(:millisecond)})
  end

  defp unmark_busy(st, vm_id), do: update_in(st.busy, &Map.delete(&1, vm_id))

  defp warm_put(st, vm_id), do: update_in(st.warm, &MapSet.put(&1, vm_id))
  defp warm_take(st, vm_id), do: update_in(st.warm, &MapSet.delete(&1, vm_id))

  defp maybe_keep_warm(st, vm_id) do
    # Keep warm up to target; otherwise stop it
    target = Config.warm_target()

    if MapSet.size(st.warm) < target do
      warm_put(st, vm_id)
    else
      stop_vm(st, vm_id)
    end
  end

  defp stop_vm(st, vm_id) do
    if pid = st.pid[vm_id] do
      DynamicSupervisor.terminate_child(VMSup, pid)
    end

    st
    |> update_in([:pid], &Map.delete(&1, vm_id))
    |> update_in([:warm], &MapSet.delete(&1, vm_id))
    |> update_in([:busy], &Map.delete(&1, vm_id))
  end
end
