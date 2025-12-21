# lib/fc_ex_cp/vm.ex
defmodule FcExCp.VM do
  @moduledoc """
  Transient GenServer.

  Restarted only if it crashes abnormally (not `:normal`, `:shutdown`)
  """
  use GenServer, restart: :transient

  require Logger

  defstruct [:id, :tenant, :status, :specs]

  def via(id), do: {:via, Registry, {FcExCp.Registry, {:vm, id}}}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def info(id), do: GenServer.call(via(id), :info)
  def boot(id), do: GenServer.call(via(id), :boot, 60_000)
  def warm_up(id), do: GenServer.call(via(id), :warm_up, 60_000)
  def update_tenant(id, tenant), do: GenServer.call(via(id), {:update_tenant, tenant})
  def stop(id), do: GenServer.stop(via(id), :normal)

  @impl true
  def init(opts) do
    id = opts[:id] || raise ArgumentError, "missing :id"
    tenant = opts[:tenant] || id
    specs = opts[:specs]
    {:ok, %__MODULE__{id: id, tenant: tenant, specs: specs, status: :init}}
  end

  @impl true
  def handle_call(:info, _from, st) do
    {:reply, %{id: st.id, tenant: st.tenant, status: st.status, specs: st.specs}, st}
  end

  @impl true
  def handle_call(:boot, _from, st) do
    firecracker = firecracker_impl()

    case firecracker.boot(st.id, st.tenant, st.specs) do
      :ok ->
        {:reply, {:ok, %{id: st.id, tenant: st.tenant, specs: st.specs, status: :running}},
         %{st | status: :running}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{st | status: {:error, reason}}}
    end
  end

  @impl true
  def handle_call(:warm_up, _from, st) do
    firecracker = firecracker_impl()

    case firecracker.warm_up(st.id, st.specs) do
      :ok ->
        {:reply, :ok, %{st | status: :warm}}

      {:error, reason} ->
        {:reply, {:error, reason}, st}
    end
  end

  @impl true
  def handle_call({:update_tenant, tenant}, _from, st) do
    # When a warm VM is attached to a job, update tenant and mark as running
    st = %{st | tenant: tenant, status: :running}
    {:reply, :ok, st}
  end

  @impl true
  def terminate(_reason, st) do
    firecracker = firecracker_impl()
    _ = firecracker.stop(st.id)
    Logger.info("VM terminate id=#{st.id} tenant=#{st.tenant}")
    :ok
  end

  defp firecracker_impl do
    Application.get_env(:fc_ex_cp, :firecracker_impl, FcExCp.Firecracker.Mock)
  end
end
