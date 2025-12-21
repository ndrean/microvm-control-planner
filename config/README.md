# VM Configuration

This directory contains configuration files for the Firecracker Control Planner.

## desired_vms.exs

Defines the VMs that should always be running. The file is loaded on application startup.

### Format

```elixir
[
  {vm_id, tenant, spec},
  ...
]
```

Where:

- `vm_id` - Unique identifier for this VM (also called `job_id` in HTTP API)
- `tenant` - Logical namespace for multi-tenancy (defaults to `vm_id` if not specified)
- `spec` - Map with VM configuration

**Terminology clarification**:

- **`vm_id` / `job_id`**: The unique identifier for a running VM instance. In the HTTP API, this is called `job_id` to emphasize the "1 job = 1 VM" model. These are interchangeable.
- **`tenant`**: The logical namespace or customer identifier. Used for isolation and accounting. If you don't need multi-tenancy, it defaults to the same value as `vm_id`.

**Example**: A single customer "acme-corp" (tenant) might run multiple VMs: "web-1", "web-2", "worker-1" (vm_ids).

### Spec Fields

| Field       | Type            | Required | Description                         |
| ----------- | --------------- | -------- | ----------------------------------- |
| `rootfs`    | string          | Yes      | Root filesystem image               |
| `kernel`    | string          | Yes      | Kernel image                        |
| `cmd`       | list of strings | Yes      | Command to run in VM                |
| `env`       | map             | No       | Environment variables               |
| `resources` | map             | Yes      | `%{vcpu: int, mem_mb: int}`         |
| `lifecycle` | string          | Yes      | `"service"`, `"job"`, or `"daemon"` |
| `warm_pool` | map             | No       | `%{min: int, max: int}`             |

### Lifecycle Types

- **`"service"`** - Long-running web apps, APIs

  - Expensive warm-up (DB dumps, CDC subscriptions)
  - Recommend `warm_pool.min >= 1`

- **`"daemon"`** - Background workers, cron jobs

  - Medium warm-up cost
  - Recommend `warm_pool.min >= 1`

- **`"job"`** - Short-lived tasks (lambdas)
  - Low warm-up cost
  - Recommend no `warm_pool` (cold starts acceptable)

### Warm Pool Configuration

```elixir
warm_pool: %{
  min: 1,  # Minimum warm VMs to maintain
  max: 3   # Maximum warm VMs allowed (future use)
}
```

**If `warm_pool` is not specified or `min: 0`, no warm VMs are maintained.**

### Example: Multi-VM Configuration

```elixir
[
  # High-traffic web service
  {"web-api", "production",
   %{
     rootfs: "rootfs-web.ext4",
     kernel: "vmlinux",
     cmd: ["/app/bin/server"],
     env: %{
       MIX_ENV: "prod",
       DATABASE_URL: "postgresql://localhost/myapp"
     },
     resources: %{vcpu: 2, mem_mb: 512},
     lifecycle: "service",
     warm_pool: %{min: 2, max: 5}  # 2 warm VMs for instant scaling
   }},

  # Background Kafka consumer
  {"kafka-consumer", "analytics",
   %{
     rootfs: "rootfs-worker.ext4",
     kernel: "vmlinux",
     cmd: ["/app/bin/consumer"],
     env: %{KAFKA_BROKERS: "broker1:9092"},
     resources: %{vcpu: 1, mem_mb: 256},
     lifecycle: "daemon",
     warm_pool: %{min: 1, max: 3}  # 1 warm for quick recovery
   }},

  # Lambda function
  {"image-resizer", "media",
   %{
     rootfs: "rootfs-lambda.ext4",
     kernel: "vmlinux",
     cmd: ["/app/bin/resize"],
     env: %{S3_BUCKET: "uploads"},
     resources: %{vcpu: 1, mem_mb: 128},
     lifecycle: "job"
     # No warm_pool - cold starts acceptable
   }}
]
```

## Overriding Config Path

You can override the config file location in your application config:

```elixir
# config/config.exs
config :fc_ex_cp,
  desired_vms_config: "/etc/firecracker/vms.exs"
```

Or via environment variable:

```bash
FC_EX_CP_DESIRED_VMS_CONFIG=/path/to/vms.exs iex -S mix
```

## Config File vs. HTTP API

There are **two ways** to add VMs:

### 1. Config File (Static Declaration)

Edit `config/desired_vms.exs` and restart the application.

**Use for:** Base infrastructure, long-lived services

### 2. HTTP API (Dynamic Provisioning)

```bash
# Auto-generate vm_id (recommended for most cases)
curl -X POST http://localhost:8088/vms \
  -H 'Content-Type: application/json' \
  -d '{"spec": {...}}'

# Or specify vm_id explicitly
curl -X POST http://localhost:8088/vms \
  -H 'Content-Type: application/json' \
  -d '{"job_id": "web-app-2", "tenant": "prod", "spec": {...}}'
```

**Use for:** On-demand scaling, dynamic workloads

**UPSERT Behavior**: If you POST with an existing `job_id`, the spec will be **replaced** (not merged). The VM will be updated to match the new spec.

### Unified Behavior

Both methods update the **same desired state** (SQLite database). The reconciler ensures eventual consistency:

**Response Codes:**

- `201 Created` - Warm VM was available, provisioned instantly
- `202 Accepted` - No warm VM yet, reconciler will provision in 1-2 seconds
- `503 Service Unavailable` - System error (shouldn't happen in normal operation)

**Note:** HTTP API changes persist across restarts!

## Monitoring with /stats

Get detailed information about running VMs and warm pool:

```bash
curl http://localhost:8088/stats
```

**Response format**:

```json
{
  "summary": {
    "total_jobs": 3,
    "total_warm": 2
  },
  "jobs": [
    {
      "job_id": "web-app-1",
      "vm_id": "vm-abc123",
      "tenant": "production",
      "status": "running",
      "spec": {...}
    }
  ],
  "warm_pool": [
    {
      "spec_hash": "A1B2C3",
      "vm_id": "warm-def456",
      "status": "warm",
      "spec": {...}
    }
  ]
}
```

**Use cases**:

- Check if warm VMs are available before provisioning
- Monitor which VMs are running for which jobs
- Debug reconciliation issues
- Capacity planning

## Hot Reloading

Currently, config file changes require a restart:

1. Edit `config/desired_vms.exs`
2. Restart: `recompile()` in iex

**Future**: Add file watching for hot-reload.

## Validation

The config file is evaluated as Elixir code. Syntax errors will cause the application to start with an empty state and log an error.

To validate your config without starting the app:

```bash
elixir config/desired_vms.exs
```

If it returns a list, it's valid!
