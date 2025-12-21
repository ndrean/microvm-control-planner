# Hello World MicroVM Example

The simplest possible microVM example - an Alpine-based HTTP server.

## Build the Image

```bash
# From the project root
mix fc.build \
  --dockerfile examples/hello-world/Dockerfile \
  --cmd "httpd -f -p 8080 -h /var/www/html" \
  --output images/hello-world
```

This will:
1. Build the Dockerfile
2. Download Alpine kernel (~8 MB)
3. Create a 512MB rootfs with busybox httpd
4. Package everything in `images/hello-world/`

## Configure and Run

### Option 1: Config File

Add to `config/desired_vms.exs`:

```elixir
[
  {"hello-world", "demo", %{
    "kernel" => "images/hello-world/vmlinux",
    "rootfs" => "images/hello-world/rootfs.ext4",
    "cmd" => ["httpd", "-f", "-p", "8080", "-h", "/var/www/html"],
    "resources" => %{"vcpu" => 1, "mem_mb" => 128},
    "lifecycle" => "service"
  }}
]
```

Then start:
```bash
iex -S mix
```

### Option 2: HTTP API

```bash
# Start FcExCp
iex -S mix

# In another terminal, create the VM
curl -X POST http://localhost:8088/vms \
  -H 'Content-Type: application/json' \
  -d '{
    "job_id": "hello-world",
    "spec": {
      "kernel": "images/hello-world/vmlinux",
      "rootfs": "images/hello-world/rootfs.ext4",
      "cmd": ["httpd", "-f", "-p", "8080", "-h", "/var/www/html"],
      "resources": {"vcpu": 1, "mem_mb": 128},
      "lifecycle": "service"
    }
  }'
```

## Test It

```bash
# Get VM info
curl http://localhost:8088/stats

# Should show:
# {
#   "jobs": [{
#     "job_id": "hello-world",
#     "status": "running",
#     "tenant": "demo"
#   }]
# }

# Access the VM (assuming it got IP 172.16.0.2)
curl http://172.16.0.2:8080
# <h1>Hello from MicroVM!</h1>
# <p>This is running directly in Firecracker, no containers!</p>
```

## What's Happening?

1. **No Docker runtime** - The busybox httpd runs directly in the microVM
2. **Hardware isolation** - Full VM with its own kernel
3. **Fast boot** - <1 second from cold start
4. **Small footprint** - ~136 MB total (8 MB kernel + 128 MB VM)

Compare this to running the same thing in Docker:
- Docker: App + containerd + VM kernel = more overhead
- FcExCp: App + VM kernel = simpler, lighter

## Next Steps

Try modifying the Dockerfile:
- Add Node.js and run a real app
- Add Python and run Flask
- Add your own application

Then rebuild:
```bash
mix fc.build --dockerfile examples/hello-world/Dockerfile --output images/hello-world
```

The image builder makes it as easy as `docker build`!
