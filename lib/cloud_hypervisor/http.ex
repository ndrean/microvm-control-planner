defmodule FcExCp.CloudHypervisor.HTTP do
  @moduledoc """
  HTTP API client for Cloud Hypervisor.

  Cloud Hypervisor provides an HTTP API over Unix domain sockets, similar to Firecracker.
  API Documentation: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/api.md

  ## Common Endpoints

  - `GET /vmm.ping` - Health check
  - `PUT /api/v1/vm.boot` - Boot the VM (if not auto-booted)
  - `PUT /api/v1/vm.shutdown` - Graceful shutdown
  - `PUT /api/v1/vm.pause` - Pause VM
  - `PUT /api/v1/vm.resume` - Resume VM
  - `GET /api/v1/vm.info` - Get VM info
  - `PUT /api/v1/vm.power-button` - Send power button signal

  ## Differences from Firecracker

  Unlike Firecracker which requires pre-configuration via HTTP API before boot,
  Cloud Hypervisor can be configured entirely via CLI arguments and boots automatically.
  The HTTP API is primarily used for runtime operations (shutdown, pause, metrics, etc.).
  """

  alias FcExCp.Firecracker.HTTP, as: FCH

  @doc """
  Check if Cloud Hypervisor API is responding.

  ## Example

      iex> CloudHypervisor.HTTP.ping("/run/ch-vm123.sock")
      {:ok, %{status: 200, body: "OK"}}
  """
  def ping(sock_path) do
    FCH.get(sock_path, "/vmm.ping")
  end

  @doc """
  Get VM information (memory, CPU, state).

  ## Example

      iex> CloudHypervisor.HTTP.vm_info("/run/ch-vm123.sock")
      {:ok, %{status: 200, body: "{...}"}}
  """
  def vm_info(sock_path) do
    FCH.get(sock_path, "/api/v1/vm.info")
  end

  @doc """
  Gracefully shutdown the VM.

  This sends ACPI shutdown signal to the guest OS.
  """
  def shutdown(sock_path) do
    FCH.put(sock_path, "/api/v1/vm.shutdown", %{})
  end

  @doc """
  Forcefully power off the VM.

  Equivalent to pulling the power plug.
  """
  def power_button(sock_path) do
    FCH.put(sock_path, "/api/v1/vm.power-button", %{})
  end

  @doc """
  Pause the VM execution.
  """
  def pause(sock_path) do
    FCH.put(sock_path, "/api/v1/vm.pause", %{})
  end

  @doc """
  Resume the VM execution.
  """
  def resume(sock_path) do
    FCH.put(sock_path, "/api/v1/vm.resume", %{})
  end

  @doc """
  Reboot the VM.
  """
  def reboot(sock_path) do
    FCH.put(sock_path, "/api/v1/vm.reboot", %{})
  end

  @doc """
  Add a new disk to the running VM (hotplug).

  ## Example

      iex> CloudHypervisor.HTTP.add_disk(sock, %{
        path: "/path/to/disk.img",
        readonly: false
      })
  """
  def add_disk(sock_path, disk_config) do
    FCH.put(sock_path, "/api/v1/vm.add-disk", disk_config)
  end

  @doc """
  Add a new network device to the running VM (hotplug).

  ## Example

      iex> CloudHypervisor.HTTP.add_net(sock, %{
        tap: "vmtap1",
        mac: "12:34:56:78:90:ab"
      })
  """
  def add_net(sock_path, net_config) do
    FCH.put(sock_path, "/api/v1/vm.add-net", net_config)
  end

  @doc """
  Resize the VM (CPU/memory hot-add).

  ## Example

      iex> CloudHypervisor.HTTP.resize(sock, %{
        desired_vcpus: 4,
        desired_ram: 2048
      })
  """
  def resize(sock_path, resize_config) do
    FCH.put(sock_path, "/api/v1/vm.resize", resize_config)
  end

  @doc """
  Create a snapshot of the VM.

  ## Example

      iex> CloudHypervisor.HTTP.snapshot(sock, %{
        destination_url: "file:///tmp/vm-snapshot"
      })
  """
  def snapshot(sock_path, snapshot_config) do
    FCH.put(sock_path, "/api/v1/vm.snapshot", snapshot_config)
  end

  @doc """
  Restore VM from a snapshot.

  ## Example

      iex> CloudHypervisor.HTTP.restore(sock, %{
        source_url: "file:///tmp/vm-snapshot"
      })
  """
  def restore(sock_path, restore_config) do
    FCH.put(sock_path, "/api/v1/vm.restore", restore_config)
  end
end
