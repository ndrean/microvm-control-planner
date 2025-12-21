# Elixir based microVM Control Planner

DRAFT
[Building...]

POC of a Control Planner in Elixir for Firecrackers **microVMs**.

The Control Planner is itself a microVM. It allows you to run dynamically microVMs based on a declarative configuration.

```mermaid
flowchart TD
    A[External<br> HTTP, WS, CLI] --> LB(Load Balancer)
    LB -->E[[Elixir based Firecracker Control Planner]]
    E  --> |Unix domain sockets <br>local only|F(Firecracker processes<br>1 socket per Tenant µVM<br>- minimal Linux<br>- web server<br>- app)
```

Elixir makes a lot of sense for this project and really shines because of built-in concurrency and state management and supervision which makes the orchestration, control and coordination "easy".

The control planner is architectured with GenServers;

- the `DesiredStateStore` (persistent state),
- the executor `PoolManager` (runtime state),
- the control loop `Reconciler` (to ensure the runtime state matches the desired state),
- the VM supervisor `VMSup`: each VM is a dynamically supervised GenServer.

The `Reconciler` architecture is borowed from k8 in very few lines of code.
The "warm pool" is also borowed from AWS lambda provisionned machines

**What is a warm VM**? It is a VM that is booted but not yet running. Its role is to hide boot latency. A warm VM is a created and booted VM but not running. It is created per unique desired spec that is not a job everytime a VM of this type is running (within limits). The _specs/contract_ you pass that will defined what the VM will run.

**What are specs**? A VM is designed via its "rootfs" + "kernel args" + "environment/config injection". These elements are referenced in the specs that you will pass to `Firecracker` (FC).

An example of a config file:

```elixir
[
    %{
        "rootfs": "rootfs-web.ext4",
        "kernel": "vmlinux",
        "cmd": ["/app/bin/server"],
        "env": %{"MIX_ENV": "prod", "SECRET_KEY_BASE": "xyz..."},
        "resources": %{"vcpu": 2, "mem_mb": 512},
        "lifecycle": "service" # or "job" or "deamon"
        warm_pool: %{min: 1,  max: 3 }
    },
    {...}
]
```

You have a mapping between the fields in the config and FC.
The warm_pool settings will be respected by the Reconciler process.

> [TODO] filewatcher?

**How does this work**? On startup:

Application starts
└─> DesiredStateStore.init/1
└─> handle_continue(:put_desired_state)
└─> load_config_file()
└─> Read config/desired_vms.exs
└─> Insert into SQLite
└─> Reconciler picks up and starts VMs

- DesiredStateStore loads your @desired_state (the config file)
- Reconciler
  - reads the desired states and the current state.
  - detects missing job: Calls PoolManager.attach("web-app-1", spec)
- PoolManager checks warm pool:
  - Computes hash of spec
  - Looks for warm VM with matching hash
  - If found: assigns it to the job, schedules new warm VM
  - If not found: returns :no_warm_vm_available error
- Reconciler ensures warm VMs: For each unique spec in desired state, ensures one warm VM exists

For example, we want a local database (to the VM). During the VM setup, if it is in the VM specs, the local database will be setup, and then receive all the changes in the database in the background (via a bridge-server in another microVM). The VM will be ready to start with an up-to-date local replica database.

**Dynamic setup**: you have an endpoint to modify the desired state: add or remove VMs.

You can do:

```sh
curl -X POST http://localhost:8088/vms \
-H 'content-type:application/json' \
-d '{"job_id": "j3","tenant": "j3","spec": {"role": "web", "cmd": ["/app/bin/server"], "env": {"PORT": 4000, "SECRET_KEY_BASE": "xxx..."}}}'
```

> [!WARNING]
> On OSX, without an M3, you cannot run `Firecracker` (even with `lima`).

## Configuration

### Backend Selection

FcExCp supports both Firecracker (Linux x86_64) and Cloud Hypervisor (Linux/macOS, ARM64).

Configure the backend via environment variable:

```sh
# Use Firecracker (Linux x86_64 only)
FC_BACKEND=firecracker

# Use Cloud Hypervisor (cross-platform)
FC_BACKEND=cloud_hypervisor

# Then start
FC_BACKEND=xxx  iex -S mix
```

If not set, the backend is auto-detected:

- macOS → Cloud Hypervisor
- Linux → Firecracker

## Control Plan Manager (k8 like)

```mermaid
flowchart TD
    DS(Desired State Store<br>
    - contains the specs of the entities to run in a µVM
    - SQLite persistence of intents) --> R(Reconciler<br>
    - ensure **warm-up** strategy
    - Policy **convergence loop**
    - Reads DesiredStateStore
    - Compares with reality PoolManager.actual_ids
    - Calls PoolManager.attach and PoolManager.detach)
    R --> P(PoolManager PM<br>
    - Executor
    - communicates with FC to run VMs
    - Holds the VMs state)
    P --> FC(Firecracker FC<br>
    - Executes VMs operations
    - communciates via unix_socket with PM)
```
