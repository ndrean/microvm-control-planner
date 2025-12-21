defmodule FcExCp.ImageBuilderOld do
  @moduledoc """
  MicroVM Image Builder - converts Docker images to Firecracker-ready VM images.

  Makes microVM image creation as easy as containers:

  ## Usage

      # From Docker image
      ImageBuilder.build(%{
        from: "node:20-alpine",
        cmd: ["node", "server.js"],
        output: "images/myapp"
      })

      # From Dockerfile
      ImageBuilder.build(%{
        dockerfile: "Dockerfile",
        output: "images/myapp"
      })

  ## What it does

  1. Exports Docker container filesystem
  2. Downloads appropriate kernel (Alpine, Ubuntu)
  3. Creates ext4 rootfs with proper init
  4. Packages everything for FcExCp

  ## Output Structure

      images/myapp/
        ├── vmlinux         # Kernel
        ├── rootfs.ext4     # Root filesystem
        └── spec.json       # FcExCp configuration
  """

  require Logger

  @kernel_urls %{
    alpine: %{
      "3.19" =>
        "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso",
      "3.18" =>
        "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/alpine-virt-3.18.4-x86_64.iso"
    },
    ubuntu: %{
      "22.04" =>
        "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64-vmlinuz-generic"
    }
  }

  @default_rootfs_size_mb 512
  @cache_dir ".fc_ex_cp_cache"

  defstruct [
    :from,
    :dockerfile,
    :cmd,
    :env,
    :output,
    :rootfs_size_mb,
    :kernel,
    :base_os,
    :work_dir
  ]

  @type t :: %__MODULE__{}

  @doc """
  Build a microVM image from a Docker image or Dockerfile.

  ## Options

    * `:from` - Docker image name (e.g., "node:20-alpine")
    * `:dockerfile` - Path to Dockerfile (alternative to :from)
    * `:cmd` - Command to run in VM (list of strings)
    * `:env` - Environment variables (map)
    * `:output` - Output directory for built image
    * `:rootfs_size_mb` - Size of rootfs in MB (default: 512)
    * `:kernel` - Specific kernel URL or version

  ## Examples

      # Simple Node.js app
      ImageBuilder.build(%{
        from: "node:20-alpine",
        cmd: ["node", "/app/server.js"],
        output: "images/node-app"
      })

      # From Dockerfile
      ImageBuilder.build(%{
        dockerfile: "./Dockerfile",
        cmd: ["python", "app.py"],
        output: "images/python-app"
      })

      # With environment variables
      ImageBuilder.build(%{
        from: "nginx:alpine",
        cmd: ["nginx", "-g", "daemon off;"],
        env: %{"PORT" => "8080"},
        output: "images/nginx"
      })
  """
  @spec build(map()) :: {:ok, String.t()} | {:error, term()}
  def build(opts) when is_map(opts) do
    with {:ok, config} <- validate_opts(opts),
         :ok <- ensure_cache_dir(),
         {:ok, work_dir} <- create_work_dir(),
         config <- %{config | work_dir: work_dir},
         {:ok, container_id} <- prepare_container(config),
         {:ok, rootfs_tar} <- export_container(container_id, work_dir),
         :ok <- cleanup_container(container_id),
         {:ok, kernel_path} <- fetch_kernel(config),
         {:ok, rootfs_path} <- create_rootfs(config, rootfs_tar),
         :ok <- create_output_dir(config.output),
         :ok <- copy_artifacts(config, kernel_path, rootfs_path),
         :ok <- create_spec_json(config) do
      Logger.info("✓ MicroVM image ready: #{config.output}")
      {:ok, config.output}
    else
      {:error, reason} = error ->
        Logger.error("Image build failed: #{inspect(reason)}")
        error
    end
  end

  # Validation

  defp validate_opts(opts) do
    cond do
      Map.has_key?(opts, :from) ->
        validate_from_opts(opts)

      Map.has_key?(opts, :dockerfile) ->
        validate_dockerfile_opts(opts)

      true ->
        {:error, "Must specify either :from (Docker image) or :dockerfile"}
    end
  end

  defp validate_from_opts(opts) do
    config = %__MODULE__{
      from: opts[:from],
      cmd: opts[:cmd] || [],
      env: opts[:env] || %{},
      output: opts[:output] || "output",
      rootfs_size_mb: opts[:rootfs_size_mb] || @default_rootfs_size_mb,
      kernel: opts[:kernel],
      base_os: detect_base_os(opts[:from])
    }

    if is_binary(config.from) and byte_size(config.from) > 0 do
      {:ok, config}
    else
      {:error, "Invalid :from option"}
    end
  end

  defp validate_dockerfile_opts(opts) do
    if File.exists?(opts[:dockerfile]) do
      config = %__MODULE__{
        dockerfile: opts[:dockerfile],
        cmd: opts[:cmd] || [],
        env: opts[:env] || %{},
        output: opts[:output] || "output",
        rootfs_size_mb: opts[:rootfs_size_mb] || @default_rootfs_size_mb,
        kernel: opts[:kernel],
        # Default to Alpine
        base_os: :alpine
      }

      {:ok, config}
    else
      {:error, "Dockerfile not found: #{opts[:dockerfile]}"}
    end
  end

  # OS Detection

  defp detect_base_os(image_name) do
    cond do
      String.contains?(image_name, "alpine") -> :alpine
      String.contains?(image_name, "ubuntu") -> :ubuntu
      # Use Ubuntu kernel for Debian
      String.contains?(image_name, "debian") -> :ubuntu
      # Default to Alpine
      true -> :alpine
    end
  end

  # Container Preparation

  defp prepare_container(%{from: image} = _config) when is_binary(image) do
    Logger.info("Pulling Docker image: #{image}")

    case System.cmd("docker", ["pull", image], stderr_to_stdout: true) do
      {_output, 0} ->
        # Create container (don't run it, just create)
        container_name = "fc-build-#{:erlang.unique_integer([:positive])}"

        case System.cmd("docker", ["create", "--name", container_name, image],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            container_id = String.trim(output)
            {:ok, container_id}

          {error, _} ->
            {:error, "Failed to create container: #{error}"}
        end

      {error, _} ->
        {:error, "Failed to pull image: #{error}"}
    end
  end

  defp prepare_container(%{dockerfile: path} = _config) do
    Logger.info("Building from Dockerfile: #{path}")

    image_tag = "fc-build:#{:erlang.unique_integer([:positive])}"
    dockerfile_dir = Path.dirname(path)

    case System.cmd("docker", ["build", "-t", image_tag, "-f", path, dockerfile_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        prepare_container(%{from: image_tag})

      {error, _} ->
        {:error, "Failed to build Dockerfile: #{error}"}
    end
  end

  # Container Export

  defp export_container(container_id, work_dir) do
    Logger.info("Exporting container filesystem...")

    tar_path = Path.join(work_dir, "rootfs.tar")

    case System.cmd("docker", ["export", "-o", tar_path, container_id], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, tar_path}

      {error, _} ->
        {:error, "Failed to export container: #{error}"}
    end
  end

  defp cleanup_container(container_id) do
    System.cmd("docker", ["rm", container_id], stderr_to_stdout: true)
    :ok
  end

  # Kernel Management

  defp fetch_kernel(%{kernel: url} = config) when is_binary(url) do
    Logger.info("Using custom kernel: #{url}")
    download_kernel(url, config.base_os)
  end

  defp fetch_kernel(config) do
    Logger.info("Fetching kernel for #{config.base_os}...")

    kernel_url = get_kernel_url(config.base_os)
    download_kernel(kernel_url, config.base_os)
  end

  defp get_kernel_url(:alpine) do
    @kernel_urls.alpine["3.19"]
  end

  defp get_kernel_url(:ubuntu) do
    @kernel_urls.ubuntu["22.04"]
  end

  defp download_kernel(url, os_type) do
    cache_file = Path.join(@cache_dir, "kernel-#{os_type}")

    if File.exists?(cache_file) do
      Logger.info("Using cached kernel: #{cache_file}")
      {:ok, cache_file}
    else
      Logger.info("Downloading kernel from #{url}")

      case System.cmd("curl", ["-L", "-o", cache_file, url], stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, cache_file}

        {error, _} ->
          {:error, "Failed to download kernel: #{error}"}
      end
    end
  end

  # Rootfs Creation

  defp create_rootfs(config, rootfs_tar) do
    Logger.info("Creating ext4 rootfs (#{config.rootfs_size_mb}MB)...")

    rootfs_path = Path.join(config.work_dir, "rootfs.ext4")

    with :ok <- create_empty_image(rootfs_path, config.rootfs_size_mb),
         :ok <- format_ext4(rootfs_path),
         {:ok, mount_point} <- mount_rootfs(rootfs_path),
         :ok <- extract_tar(rootfs_tar, mount_point),
         :ok <- create_init_script(mount_point, config),
         :ok <- setup_networking(mount_point),
         :ok <- unmount_rootfs(mount_point) do
      {:ok, rootfs_path}
    else
      error -> error
    end
  end

  defp create_empty_image(path, size_mb) do
    case System.cmd("dd", ["if=/dev/zero", "of=#{path}", "bs=1M", "count=#{size_mb}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to create image: #{error}"}
    end
  end

  defp format_ext4(path) do
    case System.cmd("mkfs.ext4", ["-F", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to format ext4: #{error}"}
    end
  end

  defp mount_rootfs(rootfs_path) do
    mount_point = Path.join(System.tmp_dir!(), "fc-mount-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(mount_point)

    case System.cmd("sudo", ["mount", "-o", "loop", rootfs_path, mount_point],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, mount_point}

      {error, _} ->
        {:error, "Failed to mount: #{error}"}
    end
  end

  defp extract_tar(tar_path, mount_point) do
    Logger.info("Extracting filesystem...")

    case System.cmd("sudo", ["tar", "xf", tar_path, "-C", mount_point], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to extract tar: #{error}"}
    end
  end

  defp create_init_script(mount_point, config) do
    Logger.info("Creating init script...")

    cmd_str = Enum.join(config.cmd, " ")
    env_exports = Enum.map_join(config.env, "\n", fn {k, v} -> "export #{k}=\"#{v}\"" end)

    init_script = """
    #!/bin/sh
    # Generated by FcExCp ImageBuilder

    # Mount essential filesystems
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devtmpfs dev /dev
    mount -t devpts devpts /dev/pts

    # Setup networking (configured by Firecracker)
    ip link set dev lo up
    ip link set dev eth0 up

    # DHCP or static IP will be configured by Firecracker via kernel cmdline

    # Environment variables
    #{env_exports}

    # Run the application
    echo "Starting application: #{cmd_str}"
    exec #{cmd_str}
    """

    init_path = Path.join(mount_point, "init")

    with :ok <- File.write(init_path, init_script),
         {_output, 0} <- System.cmd("sudo", ["chmod", "+x", init_path], stderr_to_stdout: true) do
      :ok
    else
      {error, _} -> {:error, "Failed to create init: #{error}"}
      error -> error
    end
  end

  defp setup_networking(mount_point) do
    # Create /etc/resolv.conf for DNS
    resolv_conf = """
    nameserver 8.8.8.8
    nameserver 8.8.4.4
    """

    etc_dir = Path.join(mount_point, "etc")
    File.mkdir_p!(etc_dir)

    resolv_path = Path.join(etc_dir, "resolv.conf")
    System.cmd("sudo", ["sh", "-c", "echo '#{resolv_conf}' > #{resolv_path}"])

    :ok
  end

  defp unmount_rootfs(mount_point) do
    Logger.info("Unmounting rootfs...")

    case System.cmd("sudo", ["umount", mount_point], stderr_to_stdout: true) do
      {_output, 0} ->
        File.rm_rf!(mount_point)
        :ok

      {error, _} ->
        {:error, "Failed to unmount: #{error}"}
    end
  end

  # Output Assembly

  defp create_output_dir(output_path) do
    File.mkdir_p!(output_path)
    :ok
  end

  defp copy_artifacts(config, kernel_path, rootfs_path) do
    Logger.info("Copying artifacts to #{config.output}...")

    output_kernel = Path.join(config.output, "vmlinux")
    output_rootfs = Path.join(config.output, "rootfs.ext4")

    with :ok <- File.cp(kernel_path, output_kernel),
         :ok <- File.cp(rootfs_path, output_rootfs) do
      :ok
    else
      error -> {:error, "Failed to copy artifacts: #{inspect(error)}"}
    end
  end

  defp create_spec_json(config) do
    Logger.info("Creating spec.json...")

    spec = %{
      kernel: "vmlinux",
      rootfs: "rootfs.ext4",
      cmd: config.cmd,
      env: config.env,
      resources: %{
        vcpu: 2,
        mem_mb: config.rootfs_size_mb
      },
      lifecycle: "service"
    }

    spec_path = Path.join(config.output, "spec.json")

    case Jason.encode(spec, pretty: true) do
      {:ok, json} ->
        File.write(spec_path, json)

      error ->
        {:error, "Failed to create spec.json: #{inspect(error)}"}
    end
  end

  # Utilities

  defp ensure_cache_dir do
    File.mkdir_p!(@cache_dir)
    :ok
  end

  defp create_work_dir do
    work_dir = Path.join(System.tmp_dir!(), "fc-build-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)
    {:ok, work_dir}
  end

  @doc """
  List available base images with pre-downloaded kernels.
  """
  def list_kernels do
    IO.puts("\nAvailable Kernels:")
    IO.puts("\nAlpine:")

    Enum.each(@kernel_urls.alpine, fn {version, url} ->
      cached = if File.exists?(Path.join(@cache_dir, "kernel-alpine")), do: " (cached)", else: ""
      IO.puts("  #{version}: #{url}#{cached}")
    end)

    IO.puts("\nUbuntu:")

    Enum.each(@kernel_urls.ubuntu, fn {version, url} ->
      cached = if File.exists?(Path.join(@cache_dir, "kernel-ubuntu")), do: " (cached)", else: ""
      IO.puts("  #{version}: #{url}#{cached}")
    end)
  end

  @doc """
  Clear the kernel cache.
  """
  def clear_cache do
    File.rm_rf!(@cache_dir)
    Logger.info("Cache cleared")
    :ok
  end
end
