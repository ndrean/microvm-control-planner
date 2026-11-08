defmodule FcExCp.ControlPlaneTest do
  use FcExCp.ControlPlaneCase, async: false

  test "tests start with empty, isolated desired state and no VMs" do
    assert DesiredStateStore.list() == %{}
    assert PoolManager.actual_ids() == MapSet.new()
    assert child_count() == 0
    assert Application.fetch_env!(:fc_ex_cp, :vm_module) == FcExCp.VMMock
    refute Application.fetch_env!(:fc_ex_cp, :start_control_plane)
  end

  test "cold boots workloads without a warm-pool policy and is idempotent" do
    put_job("web", spec())
    assert :ok = Reconciler.reconcile()
    assert {:ok, %{status: :running, id: id}} = PoolManager.lookup("web")
    assert :ok = Reconciler.reconcile()
    assert {:ok, %{id: ^id}} = PoolManager.lookup("web")
    assert child_count() == 1
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 0}
  end

  test "jobs cold boot and never create warm capacity" do
    put_job("job", spec(%{"lifecycle" => "job", "warm_pool" => %{"min" => 3, "max" => 3}}))
    Reconciler.reconcile()
    assert {:ok, %{status: :running}} = PoolManager.lookup("job")
    refute PoolManager.has_warm?()
    assert child_count() == 1
  end

  test "zero warm minimum still provisions a running workload" do
    put_job("web", spec(%{"warm_pool" => %{"min" => 0, "max" => 2}}))
    Reconciler.reconcile()
    assert {:ok, %{status: :running}} = PoolManager.lookup("web")
    assert child_count() == 1
  end

  test "maintains the requested warm count, reuses a VM, then replenishes" do
    spec = spec(%{"warm_pool" => %{"min" => 2, "max" => 3}})
    put_job("web-1", spec)
    Reconciler.reconcile()
    stats = PoolManager.stats()
    assert stats.summary == %{total_jobs: 1, total_warm: 2}
    warm_ids = Enum.map(stats.warm_pool, & &1.vm_id)

    put_job("web-2", spec, "tenant-2")
    assert {:ok, info} = PoolManager.attach("web-2", spec)
    assert info.id in warm_ids
    assert info.tenant == "tenant-2"
    assert info.status == :running
    assert child_count() == 3

    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 2, total_warm: 2}
    assert child_count() == 4
  end

  test "warm maximum caps an excessive minimum" do
    put_job("web", spec(%{"warm_pool" => %{"min" => 4, "max" => 2}}))
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 2}
  end

  test "a changed spec replaces the running VM and removes obsolete warm VMs" do
    original = spec(%{"warm_pool" => %{"min" => 2, "max" => 2}})
    put_job("web", original)
    Reconciler.reconcile()
    {:ok, old} = PoolManager.lookup("web")
    old_pids = for {_, pid, _, _} <- DynamicSupervisor.which_children(FcExCp.VMSup), do: pid

    updated = Map.put(original, "rootfs", "new-rootfs")
    put_job("web", updated)
    Reconciler.reconcile()
    assert {:ok, current} = PoolManager.lookup("web")
    assert current.id != old.id
    assert current.specs == updated
    assert Enum.all?(old_pids, &(not Process.alive?(&1)))
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 2}
    assert child_count() == 3
  end

  test "a tenant change replaces the existing assignment" do
    put_job("web", spec(), "tenant-1")
    Reconciler.reconcile()
    {:ok, old} = PoolManager.lookup("web")
    old_pid = vm_pid(old.id)
    put_job("web", spec(), "tenant-2")
    Reconciler.reconcile()
    assert {:ok, %{tenant: "tenant-2", id: id}} = PoolManager.lookup("web")
    assert id != old.id
    refute Process.alive?(old_pid)
  end

  test "deleting the last workload removes its job and warm VMs without restarts" do
    put_job("web", spec(%{"warm_pool" => %{"min" => 2}}))
    Reconciler.reconcile()
    assert child_count() == 3
    DesiredStateStore.delete("web")
    Reconciler.reconcile()
    Reconciler.reconcile()
    assert PoolManager.lookup("web") == :error
    assert PoolManager.stats().summary == %{total_jobs: 0, total_warm: 0}
    assert child_count() == 0
  end

  test "removing one workload retains shared warm capacity" do
    spec = spec(%{"warm_pool" => %{"min" => 1}})
    put_job("one", spec)
    put_job("two", spec)
    Reconciler.reconcile()
    DesiredStateStore.delete("one")
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 1}
  end

  @tag max_vms: 2
  test "running workloads take capacity from warm VMs" do
    put_job("web", spec(%{"warm_pool" => %{"min" => 3}}))
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 1}
    put_job("worker", spec(%{"lifecycle" => "job"}))
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 2, total_warm: 0}
    assert child_count() == 2
  end

  @tag max_vms: 1
  test "capacity failures remain desired and recover when a slot is released" do
    put_job("a", spec())
    put_job("b", spec())
    Reconciler.reconcile()
    assert {:ok, _} = PoolManager.lookup("a")
    assert :error = PoolManager.lookup("b")
    assert {:ok, _} = DesiredStateStore.get("b")
    assert child_count() == 1
    DesiredStateStore.delete("a")
    Reconciler.reconcile()
    assert {:ok, _} = PoolManager.lookup("b")
    assert child_count() == 1
  end

  @tag capture_log: true
  test "start and boot failures leave the manager and healthy jobs alive" do
    put_job("healthy", spec())
    Reconciler.reconcile()
    {:ok, healthy} = PoolManager.lookup("healthy")
    manager = Process.whereis(PoolManager)

    for failure <- ["start_error", "boot_error", "boot_crash"] do
      put_job("broken", spec(%{failure => true}))
      Reconciler.reconcile()
      assert Process.whereis(PoolManager) == manager
      assert {:ok, %{id: id}} = PoolManager.lookup("healthy")
      assert id == healthy.id
      assert PoolManager.lookup("broken") == :error
      assert child_count() == 1
    end

    put_job("broken", spec())
    Reconciler.reconcile()
    assert {:ok, _} = PoolManager.lookup("broken")
    assert child_count() == 2
  end

  @tag capture_log: true
  test "warm-up failure cleans up the child and can be retried" do
    put_job("web", spec(%{"warm_error" => true, "warm_pool" => %{"min" => 1}}))
    Reconciler.reconcile()
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 0}
    assert child_count() == 1
    assert Process.alive?(Process.whereis(PoolManager))
  end

  test "a dead assigned VM is recreated on the next pass" do
    put_job("web", spec())
    Reconciler.reconcile()
    {:ok, old} = PoolManager.lookup("web")
    pid = vm_pid(old.id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    Reconciler.reconcile()
    assert {:ok, %{id: id}} = PoolManager.lookup("web")
    assert id != old.id
    assert child_count() == 1
  end

  test "dead warm VMs are replaced before they can be assigned" do
    spec = spec(%{"warm_pool" => %{"min" => 1}})
    put_job("web", spec)
    Reconciler.reconcile()
    [warm] = PoolManager.stats().warm_pool
    pid = vm_pid(warm.vm_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    put_job("second", spec)
    Reconciler.reconcile()
    assert {:ok, %{id: id}} = PoolManager.lookup("second")
    assert id != warm.vm_id
    assert PoolManager.stats().summary == %{total_jobs: 2, total_warm: 1}
  end

  test "atom-keyed specs match their SQLite JSON representation" do
    spec = %{kernel: "kernel", rootfs: "rootfs", resources: %{vcpu: 1}, lifecycle: "job"}
    put_job("job", spec)
    {:ok, before} = PoolManager.attach("job", spec)
    Reconciler.reconcile()
    assert {:ok, after_reconcile} = PoolManager.lookup("job")
    assert before.id == after_reconcile.id
    assert after_reconcile.specs["resources"] == %{"vcpu" => 1}
  end

  test "attaching a deleted job returns an error instead of crashing" do
    assert PoolManager.attach("missing", spec()) == {:error, :not_desired}
    assert child_count() == 0
  end

  test "the configured mock backend works and restarting the manager clears orphan children" do
    put_job("web", spec())
    Reconciler.reconcile()
    stop_supervised!(PoolManager)

    {:ok, orphan} =
      DynamicSupervisor.start_child(
        FcExCp.VMSup,
        {FcExCp.VMMock, [id: "orphan", tenant: :warm, specs: spec()]}
      )

    # No explicit vm_module: exercise the actual test environment configuration.
    start_supervised!({PoolManager, max_vms: 10})
    refute Process.alive?(orphan)
    assert child_count() == 0
    Reconciler.reconcile()
    assert {:ok, %{status: :running}} = PoolManager.lookup("web")
    assert child_count() == 1
  end

  test "disabling warm capacity removes all old reserves" do
    put_job("web", spec(%{"warm_pool" => %{"min" => 2}}))
    Reconciler.reconcile()
    assert PoolManager.stats().summary.total_warm == 2
    put_job("web", spec(%{"warm_pool" => %{"min" => 0}}))
    Reconciler.reconcile()
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 0}
    assert child_count() == 1
  end
end
