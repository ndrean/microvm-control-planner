# lib/fc_ex_cp/reconciler.ex  (CALLS PoolManager.attach/detach)
defmodule FcExCp.Reconciler do
  @moduledoc """
  Reconciliation loop that ensures actual state matches desired state.

  Responsibilities:
  - Attach jobs that should exist but don't (desired - actual)
  - Detach jobs that exist but shouldn't (actual - desired)
  - Maintain warm pool based on spec configuration (warm_pool.min)

  Runs every 1 second to converge state.
  """
  use GenServer

  alias FcExCp.{DesiredStateStore, PoolManager}

  @interval 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    init_vm_spec = DesiredStateStore.list()
    schedule()
    {:ok, init_vm_spec}
  end

  @impl true
  def handle_info(:reconcile, st) do
    desired_ids = desired_job_ids()
    actual_ids = PoolManager.actual_ids()

    # jobs that SHOULD exist but DON'T
    to_attach = MapSet.difference(desired_ids, actual_ids)

    # jobs that EXIST but SHOULDN'T
    to_detach = MapSet.difference(actual_ids, desired_ids)

    Enum.each(to_attach, fn job_id ->
      {:ok, %{spec: spec}} = DesiredStateStore.get(job_id)
      _ = PoolManager.attach(job_id, spec)
    end)

    Enum.each(to_detach, fn job_id ->
      PoolManager.detach(job_id)
    end)

    # policy: ensure warm VMs for all unique specs
    ensure_warm_for_all_specs()
    schedule()
    {:noreply, st}
  end

  defp desired_job_ids do
    DesiredStateStore.list()
    |> Map.keys()
    |> MapSet.new()
  end

  defp ensure_warm_for_all_specs do
    # Get all specs that want warm pool (warm_pool.min > 0)
    desired_specs_with_warm =
      DesiredStateStore.list()
      |> Map.values()
      |> Enum.map(& &1.spec)
      |> Enum.filter(&should_keep_warm?/1)

    desired_hashes =
      desired_specs_with_warm
      |> Enum.map(&FcExCp.SpecHash.hash/1)
      |> MapSet.new()

    warm_hashes = PoolManager.warm_spec_hashes()

    missing_hashes = MapSet.difference(desired_hashes, warm_hashes)

    Enum.each(missing_hashes, fn missing_hash ->
      # Find the corresponding spec (first match is fine since hash is unique)
      spec =
        Enum.find(desired_specs_with_warm, fn s ->
          FcExCp.SpecHash.hash(s) == missing_hash
        end)

      PoolManager.ensure_warm_one(spec)
    end)

    :ok
  end

  defp should_keep_warm?(spec) do
    # Check if spec has warm_pool config with min > 0
    case spec["warm_pool"] do
      %{"min" => min} when is_integer(min) and min > 0 -> true
      _ -> false
    end
  end

  defp schedule, do: Process.send_after(self(), :reconcile, @interval)
end
