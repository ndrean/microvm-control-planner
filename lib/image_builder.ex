defmodule FcExCp.ImageBuilder do
  @moduledoc """
  Convert Docker images to Firecracker-ready microVM images.

  ## Philosophy: Start with Docker

  Instead of reinventing the wheel, leverage Docker's ecosystem:
  1. Find or build a Docker image
  2. Test it: `docker run your-image`
  3. Convert: `ImageBuilder.build(%{from: "your-image"})`
  4. Run as microVM!

  ## Usage

      # From any Docker image
      ImageBuilder.build(%{
        from: "node:20-alpine",
        output: "images/node-app"
      })

  ## What it does

  1. Pulls Docker image (if needed)
  2. Exports container filesystem
  3. Downloads appropriate kernel
  4. Creates bootable ext4 rootfs
  5. Packages for FcExCp

  ## Output

      images/node-app/
        ├── vmlinux      - Kernel (~8MB for Alpine)
        ├── rootfs.ext4  - Root filesystem
        └── spec.json    - FcExCp config
  """

  require Logger

  # Kernel URLs - only Alpine and Ubuntu for now
  @kernels %{
    alpine:
      "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso",
    ubuntu:
      "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-vmlinuz-generic"
  }

  @cache_dir ".fc_cache"
  @default_size_mb 512

  @doc """
  Build a microVM image from a Docker image.

  ## Options

    * `:from` - Docker image (required) - e.g., "node:20-alpine"
    * `:cmd` - Override container CMD (optional)
    * `:env` - Additional environment variables (optional)
    * `:output` - Output directory (default: "output")
    * `:size_mb` - Rootfs size in MB (default: 512)

  ## Examples

      # Simplest - use image defaults
      ImageBuilder.build(%{from: "nginx:alpine"})

      # Override command
      ImageBuilder.build(%{
        from: "node:20-alpine",
        cmd: ["node", "server.js"],
        output: "images/my-app"
      })

      # Add environment
      ImageBuilder.build(%{
        from: "python:3.11-alpine",
        env: %{"FLASK_ENV" => "production"},
        output: "images/flask"
      })
  """
  def build(opts) do
    Logger.info("Building microVM from Docker image...")

    with {:ok, config} <- parse_opts(opts),
         :ok <- ensure_dirs(),
         {:ok, work_dir} <- temp_dir(),
         {:ok, container} <- create_container(config.from),
         {:ok, tar} <- export_filesystem(container, work_dir),
         :ok <- cleanup_container(container),
         {:ok, kernel} <- get_kernel(config.os),
         {:ok, rootfs} <- build_rootfs(tar, work_dir, config),
         :ok <- assemble_output(config, kernel, rootfs) do
      Logger.info("✓ Image ready: #{config.output}/")
      {:ok, config.output}
    else
      {:error, reason} ->
        Logger.error("Build failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Parse and validate options
  defp parse_opts(opts) do
    unless opts[:from] do
      Logger.error({:error, "Missing required :from option (Docker image name)"})
    end

    config = %{
      from: opts[:from],
      cmd: opts[:cmd],
      env: opts[:env] || %{},
      output: opts[:output] || "output",
      size_mb: opts[:size_mb] || @default_size_mb,
      os: detect_os(opts[:from])
    }

    {:ok, config}
  end

  # Detect OS from image name
  defp detect_os(image) do
    cond do
      String.contains?(image, "alpine") -> :alpine
      String.contains?(image, "ubuntu") -> :ubuntu
      String.contains?(image, "debian") -> :ubuntu
      # Default to Alpine
      true -> :alpine
    end
  end

  # Container operations
  defp create_container(image) do
    Logger.info("Creating container from #{image}...")

    # Pull image first
    case cmd("docker", ["pull", image]) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("Could not pull #{image}, trying with local image...")
    end

    # Create container (don't start it)
    name = "fc-build-#{:rand.uniform(999_999)}"

    case cmd("docker", ["create", "--name", name, image]) do
      {:ok, _} -> {:ok, name}
      {:error, reason} -> {:error, "Failed to create container: #{reason}"}
    end
  end

  defp export_filesystem(container, work_dir) do
    Logger.info("Exporting filesystem...")
    tar = Path.join(work_dir, "rootfs.tar")

    case cmd("docker", ["export", "-o", tar, container]) do
      {:ok, _} -> {:ok, tar}
      {:error, reason} -> {:error, "Export failed: #{reason}"}
    end
  end

  defp cleanup_container(container) do
    cmd("docker", ["rm", container])
    :ok
  end

  # Kernel management
  defp get_kernel(os) do
    Logger.info("Fetching #{os} kernel...")

    kernel_file = Path.join(@cache_dir, "vmlinux-#{os}")

    if File.exists?(kernel_file) do
      Logger.info("Using cached kernel")
      {:ok, kernel_file}
    else
      download_kernel(os, kernel_file)
    end
  end

  defp download_kernel(os, dest) do
    url = @kernels[os]
    Logger.info("Downloading from #{url}")

    case cmd("curl", ["-L", "-o", dest, url]) do
      {:ok, _} -> {:ok, dest}
      {:error, reason} -> {:error, "Kernel download failed: #{reason}"}
    end
  end

  # Rootfs creation
  defp build_rootfs(tar, work_dir, config) do
    Logger.info("Building rootfs (#{config.size_mb}MB)...")

    rootfs = Path.join(work_dir, "rootfs.ext4")

    with :ok <- create_image(rootfs, config.size_mb),
         :ok <- format_image(rootfs),
         {:ok, mount} <- mount_image(rootfs),
         :ok <- extract_filesystem(tar, mount),
         :ok <- write_init(mount, config),
         :ok <- unmount_image(mount) do
      {:ok, rootfs}
    end
  end

  defp create_image(path, size_mb) do
    case cmd("dd", ["if=/dev/zero", "of=#{path}", "bs=1M", "count=#{size_mb}"], quiet: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "dd failed: #{reason}"}
    end
  end

  defp format_image(path) do
    case cmd("mkfs.ext4", ["-F", path], quiet: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "mkfs.ext4 failed: #{reason}"}
    end
  end

  defp mount_image(rootfs) do
    mount_point = Path.join(System.tmp_dir!(), "fc-mount-#{:rand.uniform(999_999)}")
    File.mkdir_p!(mount_point)

    case cmd("sudo", ["mount", "-o", "loop", rootfs, mount_point]) do
      {:ok, _} -> {:ok, mount_point}
      {:error, reason} -> {:error, "mount failed: #{reason}"}
    end
  end

  defp extract_filesystem(tar, mount) do
    Logger.info("Extracting filesystem...")

    case cmd("sudo", ["tar", "xf", tar, "-C", mount], quiet: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "tar extraction failed: #{reason}"}
    end
  end

  defp write_init(mount, config) do
    Logger.info("Creating init script...")

    # Build command string
    cmd_str =
      if config.cmd do
        Enum.join(config.cmd, " ")
      else
        # Try to read CMD from container (future enhancement)
        "/bin/sh"
      end

    # Build env exports
    env_str =
      config.env
      |> Enum.map(fn {k, v} -> "export #{k}=\"#{v}\"" end)
      |> Enum.join("\n")

    init = """
    #!/bin/sh
    # FcExCp init

    # Mount core filesystems
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devtmpfs dev /dev

    # Network
    ip link set lo up
    ip link set eth0 up

    # Environment
    #{env_str}

    # Run app
    exec #{cmd_str}
    """

    init_path = Path.join(mount, "init")

    with :ok <- File.write(init_path, init),
         {:ok, _} <- cmd("sudo", ["chmod", "+x", init_path]) do
      :ok
    else
      error -> {:error, "init creation failed: #{inspect(error)}"}
    end
  end

  defp unmount_image(mount) do
    case cmd("sudo", ["umount", mount]) do
      {:ok, _} ->
        File.rm_rf!(mount)
        :ok

      {:error, reason} ->
        {:error, "unmount failed: #{reason}"}
    end
  end

  # Output assembly
  defp assemble_output(config, kernel, rootfs) do
    Logger.info("Assembling output...")

    File.mkdir_p!(config.output)

    # Copy artifacts
    File.cp!(kernel, Path.join(config.output, "vmlinux"))
    File.cp!(rootfs, Path.join(config.output, "rootfs.ext4"))

    # Create spec.json
    spec = %{
      kernel: "vmlinux",
      rootfs: "rootfs.ext4",
      cmd: config.cmd || [],
      env: config.env,
      resources: %{vcpu: 2, mem_mb: config.size_mb},
      lifecycle: "service"
    }

    spec_json = Jason.encode!(spec, pretty: true)
    File.write!(Path.join(config.output, "spec.json"), spec_json)

    :ok
  end

  # Utilities
  defp ensure_dirs do
    File.mkdir_p!(@cache_dir)
    :ok
  end

  defp temp_dir do
    dir = Path.join(System.tmp_dir!(), "fc-build-#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  defp cmd(bin, args, opts \\ []) do
    quiet = Keyword.get(opts, :quiet, false)

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} ->
        unless quiet, do: Logger.debug(output)
        {:ok, output}

      {output, code} ->
        {:error, "#{bin} exited #{code}: #{output}"}
    end
  end

  @doc "Clear the kernel cache"
  def clear_cache do
    File.rm_rf!(@cache_dir)
    Logger.info("Cache cleared")
  end
end
