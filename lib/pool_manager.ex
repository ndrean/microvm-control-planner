# lib/fc_ex_cp/pool_manager.ex  (COHERENT: attach(job_id) only)
defmodule FcExCp.PoolManager do
  @moduledoc false
  use GenServer

  alias FcExCp.{VM, VMSup, SpecHash, DesiredStateStore}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # 1 job = 1 VM. tenant defaults to job_id (or comes from DesiredStateStore)
  def attach(job_id, spec), do: GenServer.call(__MODULE__, {:attach, job_id, spec}, 60_000)
  def detach(job_id), do: GenServer.cast(__MODULE__, {:detach, job_id})

  def ensure_warm_one(spec) do
    GenServer.cast(__MODULE__, {:ensure_warm_one, spec})
  end

  def warm_spec_hashes(), do: GenServer.call(__MODULE__, :warm_spec_hashes)

  def lookup(job_id), do: GenServer.call(__MODULE__, {:lookup, job_id})
  def stats(), do: GenServer.call(__MODULE__, :stats)

  # Used by Reconciler to compare reality (PoolManager view)
  def actual_ids(), do: GenServer.call(__MODULE__, :actual_ids)

  def has_warm?(), do: GenServer.call(__MODULE__, :has_warm?)

  @impl true
  def init(_opts) do
    # State structure:
    # %{
    #   jobs: %{job_id => %{vm_id: "vm-123", spec_hash: "A1B2", tenant: "t1"}},
    #   warm_pool: %{spec_hash => %{vm_id: "warm-456", spec: %{...}}}
    # }
    {:ok, %{jobs: %{}, warm_pool: %{}}}
  end

  @impl true
  def handle_call(:stats, _from, st) do
    # Build detailed job list
    jobs_list =
      for {job_id, %{vm_id: vm_id, tenant: tenant}} <- st.jobs do
        vm_info = VM.info(vm_id)

        %{
          job_id: job_id,
          vm_id: vm_id,
          tenant: tenant,
          status: vm_info.status,
          spec: vm_info.specs
        }
      end

    # Build detailed warm pool list
    warm_pool_list =
      for {spec_hash, %{vm_id: vm_id, spec: spec}} <- st.warm_pool do
        vm_info = VM.info(vm_id)

        # Find which desired VMs use this spec to identify the workload
        desired_vms = DesiredStateStore.list()
        matching_vm_ids =
          desired_vms
          |> Enum.filter(fn {_vm_id, %{spec: desired_spec}} ->
            SpecHash.hash(desired_spec) == spec_hash
          end)
          |> Enum.map(fn {vm_id, _} -> vm_id end)

        # Create a profile showing lifecycle and which workload(s) this serves
        lifecycle = spec["lifecycle"] || "unknown"
        workload =
          case matching_vm_ids do
            [single] -> "#{lifecycle}-#{single}"
            multiple when length(multiple) > 1 -> "#{lifecycle}-#{Enum.join(multiple, ",")}"
            [] -> "#{lifecycle}-orphaned"
          end

        %{
          spec_hash: spec_hash,
          vm_id: vm_id,
          status: vm_info.status,
          profile: workload,
          for_workloads: matching_vm_ids,
          spec: spec
        }
      end

    {:reply,
     %{
       summary: %{
         total_jobs: map_size(st.jobs),
         total_warm: map_size(st.warm_pool)
       },
       jobs: jobs_list,
       warm_pool: warm_pool_list
     }, st}
  end

  @impl true
  def handle_call(:actual_ids, _from, st) do
    {:reply, Map.keys(st.jobs) |> MapSet.new(), st}
  end

  @impl true
  def handle_call(:has_warm?, _from, st) do
    {:reply, map_size(st.warm_pool) > 0, st}
  end

  @impl true
  def handle_call(:warm_spec_hashes, _from, st) do
    {:reply, st.warm_pool |> Map.keys() |> MapSet.new(), st}
  end

  @impl true
  def handle_call({:lookup, job_id}, _from, st) do
    case st.jobs[job_id] do
      nil ->
        {:reply, :error, st}

      %{vm_id: vm_id} ->
        {:reply, {:ok, VM.info(vm_id)}, st}
    end
  rescue
    _ -> {:reply, :error, st}
  end

  @impl true
  def handle_call({:attach, job_id, spec}, _from, st) do
    # make it idempotent
    case st.jobs[job_id] do
      nil ->
        {:ok, %{tenant: tenant}} = DesiredStateStore.get(job_id)
        spec_hash = SpecHash.hash(spec)

        # Try to find a warm VM with matching spec
        case st.warm_pool[spec_hash] do
          nil ->
            {:reply, {:error, :no_warm_vm_available}, st}

          %{vm_id: warm_vm_id} ->
            # Remove from warm pool and assign to job
            st =
              st
              |> put_in(
                [:jobs, job_id],
                %{vm_id: warm_vm_id, spec_hash: spec_hash, tenant: tenant}
              )
              |> update_in([:warm_pool], &Map.delete(&1, spec_hash))

            # Update the VM's tenant metadata (VM is already booted)
            :ok = VM.update_tenant(warm_vm_id, tenant)

            # Schedule a new warm VM with this spec
            ensure_warm_one(spec)

            {:reply, {:ok, VM.info(warm_vm_id)}, st}
        end

      %{vm_id: vm_id} ->
        # idempotent step - already attached
        {:reply, {:ok, VM.info(vm_id)}, st}
    end
  end

  @impl true
  def handle_cast({:ensure_warm_one, spec}, st) do
    spec_hash = SpecHash.hash(spec)

    # Only create if we don't already have a warm VM for this spec
    case st.warm_pool[spec_hash] do
      nil ->
        vm_id = "warm-#{spec_hash}-#{:erlang.unique_integer([:positive])}"
        vm_spec = {VM, [id: vm_id, tenant: :warm, specs: spec]}

        case DynamicSupervisor.start_child(VMSup, vm_spec) do
          {:ok, _pid} ->
            # Boot immediately to hide latency
            {:ok, _} = VM.boot(vm_id)
            # Warm up: dump DB, start CDC, pre-load dependencies
            :ok = VM.warm_up(vm_id)
            st = put_in(st, [:warm_pool, spec_hash], %{vm_id: vm_id, spec: spec})
            {:noreply, st}

          {:error, reason} ->
            {:stop, {:error, reason}, st}
        end

      _existing_warm ->
        # Already have a warm VM for this spec
        {:noreply, st}
    end
  end

  @impl true
  def handle_cast({:detach, job_id}, st) do
    case st.jobs[job_id] do
      nil ->
        {:noreply, st}

      %{vm_id: vm_id, spec_hash: spec_hash} ->
        # Remove from jobs
        st = update_in(st.jobs, &Map.delete(&1, job_id))

        # Try to return to warm pool if slot is available
        st =
          case st.warm_pool[spec_hash] do
            nil ->
              # Get the spec from another job with same spec_hash, or we need to store it
              # For now, just stop the VM since we can't reconstruct the spec
              VM.stop(vm_id)
              st

            _already_have_warm ->
              # Already have a warm VM for this spec, stop this one
              VM.stop(vm_id)
              st
          end

        {:noreply, st}
    end
  end

  @impl true
  def terminate(_reason, st) do
    # stop all job VMs
    Enum.each(st.jobs, fn {_job_id, %{vm_id: vm_id}} ->
      VM.stop(vm_id)
    end)

    # stop all warm VMs
    Enum.each(st.warm_pool, fn {_spec_hash, %{vm_id: vm_id}} ->
      VM.stop(vm_id)
    end)

    :ok
  end

  # defp start_warm_vm(st) do
  #   vm_id = "warm-#{System.unique_integer([:positive])}"

  #   # start a dynamic VM runner process
  #   spec = {FcExCp.VM, [id: vm_id, tenant: :warm]}
  #   {:ok, _pid} = DynamicSupervisor.start_child(FcExCp.VMSup, spec)
  #   {:ok, %{id: ^vm_id, status: :running}} = FcExCp.VM.boot(vm_id)

  #   %{st | warm: vm_id}
  # end
end
