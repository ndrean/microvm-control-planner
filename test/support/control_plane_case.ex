defmodule FcExCp.ControlPlaneCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias FcExCp.{DesiredStateStore, PoolManager, Reconciler}
      import FcExCp.ControlPlaneCase
    end
  end

  setup tags do
    previous = Application.fetch_env!(:fc_ex_cp, :firecracker_impl)
    Application.put_env(:fc_ex_cp, :firecracker_impl, FcExCp.TestHypervisor)
    on_exit(fn -> Application.put_env(:fc_ex_cp, :firecracker_impl, previous) end)

    start_supervised!({Registry, keys: :unique, name: FcExCp.Registry})
    start_supervised!({FcExCp.DesiredStateStore, [":memory:"]})
    start_supervised!({DynamicSupervisor, name: FcExCp.VMSup, strategy: :one_for_one})

    start_supervised!(
      {FcExCp.PoolManager, max_vms: Map.get(tags, :max_vms, 10), vm_module: FcExCp.TestVM}
    )

    start_supervised!({FcExCp.Reconciler, interval: :infinity})
    :ok
  end

  def spec(overrides \\ %{}) do
    Map.merge(
      %{
        "kernel" => "test-kernel",
        "rootfs" => "test-rootfs",
        "lifecycle" => "service",
        "resources" => %{"vcpu" => 1, "mem_mb" => 128}
      },
      overrides
    )
  end

  def put_job(id, spec, tenant \\ nil) do
    :ok = FcExCp.DesiredStateStore.put(id, tenant || id, spec)
  end

  def vm_pid(vm_id) do
    [{pid, _}] = Registry.lookup(FcExCp.Registry, {:vm, vm_id})
    pid
  end

  def child_count(), do: DynamicSupervisor.count_children(FcExCp.VMSup).active
end

defmodule FcExCp.TestVM do
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    if opts[:specs]["start_error"],
      do: {:error, :start_failed},
      else: FcExCp.VMMock.start_link(opts)
  end

  defdelegate info(id), to: FcExCp.VMMock
  defdelegate boot(id), to: FcExCp.VMMock
  defdelegate warm_up(id), to: FcExCp.VMMock
  defdelegate update_tenant(id, tenant), to: FcExCp.VMMock
  defdelegate stop(id), to: FcExCp.VMMock
end

defmodule FcExCp.TestHypervisor do
  @behaviour FcExCp.Firecracker

  @impl true
  def boot(_id, _tenant, %{"boot_error" => true}), do: {:error, :boot_failed}
  def boot(_id, _tenant, %{"boot_crash" => true}), do: exit(:boot_crashed)
  def boot(id, tenant, spec), do: FcExCp.Firecracker.Mock.boot(id, tenant, spec)

  @impl true
  def warm_up(_id, %{"warm_error" => true}), do: {:error, :warm_failed}
  def warm_up(id, spec), do: FcExCp.Firecracker.Mock.warm_up(id, spec)

  @impl true
  defdelegate stop(id), to: FcExCp.Firecracker.Mock
end
