# Desired VM Configuration
# This file defines the VMs that should always be running.
# Format: list of {vm_id, tenant, spec} tuples

[
  {"web-app-1", "web-app-1",
   %{
     rootfs: "rootfs-web.ext4",
     kernel: "vmlinux",
     cmd: ["/app/bin/server"],
     env: %{
       MIX_ENV: "prod",
       SECRET_KEY_BASE: "xyz...",
       DATABASE_URL: "postgresql://localhost/myapp"
     },
     resources: %{vcpu: 2, mem_mb: 512},
     # Lifecycle: "service" (long-running), "job" (short-lived), "daemon" (background)
     lifecycle: "service",
     # Warm pool configuration
     warm_pool: %{
       min: 1,  # Always keep at least 1 warm VM ready
       max: 3   # Cap at 3 to limit resource usage
     }
   }},

  # Example: Database-heavy analytics service
  # Uncomment to enable:
  # {"reports-api", "analytics",
  #  %{
  #    rootfs: "rootfs-reports.ext4",
  #    kernel: "vmlinux",
  #    cmd: ["/app/bin/reports"],
  #    env: %{DATA_DIR: "/mnt/data", CACHE_SIZE_GB: "8"},
  #    resources: %{vcpu: 4, mem_mb: 8192},
  #    lifecycle: "service",
  #    warm_pool: %{min: 1, max: 2}
  #  }},

  # Example: Background worker (no warm pool needed)
  # {"kafka-consumer", "analytics",
  #  %{
  #    rootfs: "rootfs-worker.ext4",
  #    kernel: "vmlinux",
  #    cmd: ["/app/bin/consumer"],
  #    env: %{KAFKA_BROKERS: "broker1:9092"},
  #    resources: %{vcpu: 1, mem_mb: 256},
  #    lifecycle: "daemon",
  #    warm_pool: %{min: 1, max: 3}
  #  }},

  # Example: Lambda job (no warm pool)
  # {"image-resizer", "media",
  #  %{
  #    rootfs: "rootfs-lambda.ext4",
  #    kernel: "vmlinux",
  #    cmd: ["/app/bin/resize"],
  #    env: %{S3_BUCKET: "media-uploads"},
  #    resources: %{vcpu: 1, mem_mb: 128},
  #    lifecycle: "job"
  #    # No warm_pool = cold starts acceptable
  #  }}
]
