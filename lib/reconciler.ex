defmodule FcExCp.Reconciler do
  @moduledoc """
  Converges running jobs and warm capacity to a snapshot of desired state.
  Failed provisioning remains desired and is retried on the next pass.
  """
  use GenServer
  require Logger

  alias FcExCp.{DesiredStateStore, PoolManager}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one complete pass, useful for deterministic tests and manual convergence."
  def reconcile(), do: GenServer.call(__MODULE__, :reconcile, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 1_000)
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_call(:reconcile, _from, interval) do
    converge()
    {:reply, :ok, interval}
  end

  @impl true
  def handle_info(:reconcile, interval) do
    converge()
    schedule(interval)
    {:noreply, interval}
  end

  defp converge do
    desired = DesiredStateStore.list()
    desired_ids = MapSet.new(Map.keys(desired))

    PoolManager.actual_ids()
    |> MapSet.difference(desired_ids)
    |> Enum.each(&PoolManager.detach/1)

    specs = Enum.map(desired, fn {_id, value} -> value.spec end)
    PoolManager.reconcile_warm(specs, false)

    # attach is idempotent for the same spec and tenant; changed assignments
    # are replaced, and missing jobs can cold boot without a warm-pool policy.
    for {job_id, %{spec: spec}} <- Enum.sort(desired) do
      case PoolManager.attach(job_id, spec) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Cannot provision #{job_id}: #{inspect(reason)}")
      end
    end

    PoolManager.reconcile_warm(specs)
  end

  defp schedule(:infinity), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval)
end
