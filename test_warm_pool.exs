# Test script to verify warm pool behavior
# Run with: mix run test_warm_pool.exs

alias FcExCp.{PoolManager, DesiredStateStore}

IO.puts("\n=== Testing Warm Pool with Multiple Jobs ===\n")

# Wait for initial warm VM to be created
Process.sleep(1500)

IO.puts("1. Initial state:")
IO.inspect(PoolManager.stats(), label: "Stats")

# Add a second job with the same spec
spec = %{
  rootfs: "rootfs-web.ext4",
  kernel: "vmlinux",
  cmd: ["/app/bin/server"],
  env: %{MIX_ENV: "prod", SECRET_KEY_BASE: "xyz..."},
  resources: %{vcpu: 2, mem_mb: 512},
  lifecycle: "service"
}

IO.puts("\n2. Adding second job 'web-app-2'...")
:ok = DesiredStateStore.put("web-app-2", "tenant-2", spec)

# Wait for reconciler
Process.sleep(1500)

IO.puts("\n3. After adding web-app-2:")
IO.inspect(PoolManager.stats(), label: "Stats")

# Check both VMs
case PoolManager.lookup("web-app-1") do
  {:ok, info} -> IO.inspect(info, label: "web-app-1")
  :error -> IO.puts("web-app-1: not found")
end

case PoolManager.lookup("web-app-2") do
  {:ok, info} -> IO.inspect(info, label: "web-app-2")
  :error -> IO.puts("web-app-2: not found")
end

# Inspect actual VM processes
IO.puts("\n4. Checking VM tenants:")
Registry.lookup(FcExCp.Registry, {:vm, "warm-7A0B641-3"})
|> case do
  [{pid, _}] ->
    state = :sys.get_state(pid)
    IO.inspect(%{id: state.id, tenant: state.tenant, status: state.status}, label: "VM 1")
  [] -> IO.puts("VM 1: not found")
end

IO.puts("\n=== Test Complete ===\n")
