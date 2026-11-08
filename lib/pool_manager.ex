defmodule FcExCp.PoolManager do
  @moduledoc """
  Owns job assignments and warm VMs. Desired state remains in SQLite so a
  failed boot or a lost VM can be retried by the reconciler.
  """
  use GenServer
  require Logger

  alias FcExCp.{Config, DesiredStateStore, SpecHash, VMSup}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def attach(job_id, spec), do: GenServer.call(__MODULE__, {:attach, job_id, spec}, :infinity)
  def detach(job_id), do: GenServer.call(__MODULE__, {:detach, job_id}, :infinity)
  def lookup(job_id), do: GenServer.call(__MODULE__, {:lookup, job_id})
  def stats(), do: GenServer.call(__MODULE__, :stats)
  def actual_ids(), do: GenServer.call(__MODULE__, :actual_ids)
  def warm_spec_hashes(), do: GenServer.call(__MODULE__, :warm_spec_hashes)
  def has_warm?(), do: MapSet.size(warm_spec_hashes()) > 0

  # Trim before provisioning jobs; replenish only after jobs have had priority.
  def reconcile_warm(specs, replenish \\ true),
    do: GenServer.call(__MODULE__, {:reconcile_warm, specs, replenish}, :infinity)

  def ensure_warm_one(spec), do: GenServer.cast(__MODULE__, {:ensure_warm_one, spec})

  @impl true
  def init(opts) do
    # This manager is the sole owner of VMSup. A manager restart must not leave
    # untracked VMs consuming capacity while desired state is replayed.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(VMSup) do
      # Ask the VM itself to stop so its cleanup callback runs, even for a
      # backend that does not trap supervisor shutdown signals.
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      DynamicSupervisor.terminate_child(VMSup, pid)
    end

    {:ok,
     %{
       jobs: %{},
       warm_pool: %{},
       vm: Keyword.get(opts, :vm_module, Application.fetch_env!(:fc_ex_cp, :vm_module)),
       max_vms: Keyword.get(opts, :max_vms, Config.max_vms())
     }}
  end

  @impl true
  def handle_call({:attach, job_id, spec}, _from, st) do
    st = prune_dead(st)
    spec = SpecHash.normalize(spec)

    case DesiredStateStore.get(job_id) do
      {:ok, %{tenant: tenant}} ->
        hash = SpecHash.hash(spec)
        existing = st.jobs[job_id]

        if existing && existing.spec_hash == hash && existing.tenant == tenant do
          {:reply, vm_call(st, :info, [existing.vm_id]), st}
        else
          st = detach_job(st, job_id)
          {reply, st} = provision(st, job_id, tenant, spec, hash)
          {:reply, reply, st}
        end

      :error ->
        {:reply, {:error, :not_desired}, st}
    end
  end

  def handle_call({:detach, job_id}, _from, st) do
    {:reply, :ok, detach_job(st, job_id)}
  end

  def handle_call({:lookup, job_id}, _from, st) do
    st = prune_dead(st)

    reply =
      case st.jobs[job_id] do
        nil ->
          :error

        entry ->
          case vm_call(st, :info, [entry.vm_id]) do
            {:ok, info} -> {:ok, info}
            {:error, _} -> :error
          end
      end

    {:reply, reply, st}
  end

  def handle_call(:actual_ids, _from, st) do
    st = prune_dead(st)
    {:reply, MapSet.new(Map.keys(st.jobs)), st}
  end

  def handle_call(:warm_spec_hashes, _from, st) do
    st = prune_dead(st)
    {:reply, MapSet.new(Map.keys(st.warm_pool)), st}
  end

  def handle_call(:stats, _from, st) do
    st = prune_dead(st)
    desired = DesiredStateStore.list()

    jobs =
      for {job_id, entry} <- st.jobs,
          {:ok, info} <- [vm_call(st, :info, [entry.vm_id])] do
        %{
          job_id: job_id,
          vm_id: entry.vm_id,
          tenant: entry.tenant,
          status: info.status,
          spec: info.specs
        }
      end

    warm =
      for {hash, entries} <- st.warm_pool,
          entry <- entries,
          {:ok, info} <- [vm_call(st, :info, [entry.vm_id])] do
        workloads = for {id, %{spec: spec}} <- desired, SpecHash.hash(spec) == hash, do: id
        lifecycle = entry.spec["lifecycle"] || "unknown"
        profile = if workloads == [], do: "orphaned", else: Enum.join(Enum.sort(workloads), ",")

        %{
          spec_hash: hash,
          vm_id: entry.vm_id,
          status: info.status,
          profile: "#{lifecycle}-#{profile}",
          for_workloads: workloads,
          spec: entry.spec
        }
      end

    {:reply,
     %{
       summary: %{total_jobs: length(jobs), total_warm: length(warm)},
       jobs: jobs,
       warm_pool: warm
     }, st}
  end

  def handle_call({:reconcile_warm, specs, replenish}, _from, st) do
    targets = warm_targets(specs)
    st = st |> prune_dead() |> trim_warm(targets)
    st = if replenish, do: fill_warm(st, targets), else: st
    {:reply, :ok, st}
  end

  @impl true
  def handle_cast({:ensure_warm_one, spec}, st) do
    {:noreply, fill_warm(prune_dead(st), warm_targets([spec]))}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, st) do
    {:noreply, reject_entries(st, &(&1.ref == ref))}
  end

  @impl true
  def terminate(_reason, st) do
    Enum.each(all_entries(st), &stop_entry(st, &1))
  end

  defp provision(st, job_id, tenant, spec, hash) do
    case Map.get(st.warm_pool, hash, []) do
      [entry | rest] ->
        st = put_warm(st, hash, rest)

        case vm_call(st, :update_tenant, [entry.vm_id, tenant]) do
          {:ok, :ok} ->
            assign(st, entry, job_id, tenant, hash)

          {:error, reason} ->
            stop_entry(st, entry)
            {{:error, reason}, st}
        end

      [] ->
        # Warm capacity is expendable; desired workloads take precedence.
        st = make_room(st)

        case start_vm(st, tenant, spec, false) do
          {:ok, entry} -> assign(st, entry, job_id, tenant, hash)
          {:error, reason} -> {{:error, reason}, st}
        end
    end
  end

  defp assign(st, entry, job_id, tenant, hash) do
    case vm_call(st, :info, [entry.vm_id]) do
      {:ok, info} ->
        entry = Map.merge(entry, %{tenant: tenant, spec_hash: hash})
        {{:ok, info}, put_in(st, [:jobs, job_id], entry)}

      {:error, reason} ->
        stop_entry(st, entry)
        {{:error, reason}, st}
    end
  end

  defp start_vm(st, tenant, spec, warm?) do
    if length(all_entries(st)) >= st.max_vms do
      {:error, :capacity_exhausted}
    else
      id = "vm-#{System.unique_integer([:positive, :monotonic])}"
      # Reconciliation, rather than an unbooted automatic child restart, owns recovery.
      child =
        Supervisor.child_spec({st.vm, [id: id, tenant: tenant, specs: spec]}, restart: :temporary)

      case DynamicSupervisor.start_child(VMSup, child) do
        {:ok, pid} ->
          entry = %{vm_id: id, pid: pid, ref: Process.monitor(pid), spec: spec}

          result =
            with {:ok, _} <- vm_call(st, :boot, [id]),
                 {:ok, _} <- maybe_warm(st, id, warm?),
                 do: {:ok, entry}

          case result do
            {:ok, _} ->
              result

            {:error, _} ->
              stop_entry(st, entry)
              result
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_warm(st, id, true), do: vm_call(st, :warm_up, [id])
  defp maybe_warm(_st, _id, false), do: {:ok, :ok}

  # Backends may return an error, raise, or exit while handling a call. None of
  # those should take down the manager and lose every other job assignment.
  defp vm_call(st, function, args) do
    case apply(st.vm, function, args) do
      {:error, reason} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      value -> {:ok, value}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp detach_job(st, job_id) do
    case Map.pop(st.jobs, job_id) do
      {nil, _} ->
        st

      {entry, jobs} ->
        stop_entry(st, entry)
        %{st | jobs: jobs}
    end
  end

  defp stop_entry(st, entry) do
    Process.demonitor(entry.ref, [:flush])
    _ = vm_call(st, :stop, [entry.vm_id])
    # Ensure a backend's failing cleanup cannot retain a supervised child.
    DynamicSupervisor.terminate_child(VMSup, entry.pid)
    :ok
  end

  defp warm_targets(specs) do
    specs
    |> Enum.map(&SpecHash.normalize/1)
    |> Enum.reduce(%{}, fn spec, targets ->
      target = warm_target(spec)
      hash = SpecHash.hash(spec)

      Map.update(targets, hash, {spec, target}, fn {previous, count} ->
        {previous, max(count, target)}
      end)
    end)
  end

  defp warm_target(%{"lifecycle" => "job"}), do: 0

  defp warm_target(%{"warm_pool" => %{"min" => minimum} = policy})
       when is_integer(minimum) and minimum > 0 do
    maximum = Map.get(policy, "max", minimum)
    if is_integer(maximum) and maximum >= 0, do: min(minimum, maximum), else: 0
  end

  defp warm_target(_spec), do: 0

  defp trim_warm(st, targets) do
    Enum.reduce(st.warm_pool, st, fn {hash, entries}, acc ->
      {_spec, target} = Map.get(targets, hash, {nil, 0})
      {keep, remove} = Enum.split(entries, target)
      Enum.each(remove, &stop_entry(acc, &1))
      put_warm(acc, hash, keep)
    end)
  end

  defp fill_warm(st, targets) do
    Enum.reduce(targets, st, fn {hash, {spec, target}}, acc ->
      missing = target - length(Map.get(acc.warm_pool, hash, []))
      fill_spec(acc, hash, spec, max(missing, 0))
    end)
  end

  defp fill_spec(st, _hash, _spec, 0), do: st

  defp fill_spec(st, hash, spec, missing) do
    case start_vm(st, :warm, spec, true) do
      {:ok, entry} ->
        st = put_warm(st, hash, [entry | Map.get(st.warm_pool, hash, [])])
        fill_spec(st, hash, spec, missing - 1)

      {:error, :capacity_exhausted} ->
        st

      {:error, reason} ->
        Logger.warning("Warm VM provisioning failed: #{inspect(reason)}")
        st
    end
  end

  defp make_room(st) do
    if length(all_entries(st)) >= st.max_vms && map_size(st.warm_pool) > 0 do
      {hash, [entry | rest]} = Enum.at(st.warm_pool, 0)
      stop_entry(st, entry)
      put_warm(st, hash, rest)
    else
      st
    end
  end

  defp put_warm(st, hash, []), do: %{st | warm_pool: Map.delete(st.warm_pool, hash)}
  defp put_warm(st, hash, entries), do: put_in(st, [:warm_pool, hash], entries)
  defp all_entries(st), do: Map.values(st.jobs) ++ List.flatten(Map.values(st.warm_pool))
  defp prune_dead(st), do: reject_entries(st, &(not Process.alive?(&1.pid)))

  defp reject_entries(st, reject?) do
    jobs = Map.reject(st.jobs, fn {_id, entry} -> reject?.(entry) end)

    warm =
      for {hash, entries} <- st.warm_pool,
          remaining = Enum.reject(entries, reject?),
          remaining != [],
          into: %{},
          do: {hash, remaining}

    %{st | jobs: jobs, warm_pool: warm}
  end
end
