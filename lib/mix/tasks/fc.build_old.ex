defmodule Mix.Tasks.Fc.BuildOld do
  @moduledoc """
  Build microVM images from Docker images or Dockerfiles.

  Makes microVM image creation as easy as containers!

  ## Usage

      # From Docker image
      mix fc.build --from node:20-alpine --cmd "node server.js" --output images/myapp

      # From Dockerfile
      mix fc.build --dockerfile ./Dockerfile --cmd "python app.py" --output images/python-app

      # With environment variables
      mix fc.build --from nginx:alpine --cmd "nginx -g 'daemon off;'" --env PORT=8080 --output images/nginx

      # Custom rootfs size
      mix fc.build --from node:20-alpine --cmd "node app.js" --size 1024 --output images/big-app

  ## Options

    * `--from IMAGE` - Docker image to use as base
    * `--dockerfile PATH` - Path to Dockerfile (alternative to --from)
    * `--cmd COMMAND` - Command to run in the VM
    * `--env KEY=VALUE` - Environment variable (can be repeated)
    * `--output DIR` - Output directory (default: output)
    * `--size MB` - Rootfs size in MB (default: 512)
    * `--kernel URL` - Custom kernel URL

  ## Output

  Creates a directory with:
    - vmlinux (kernel)
    - rootfs.ext4 (root filesystem)
    - spec.json (FcExCp configuration)

  ## Examples

      # Node.js application
      mix fc.build \\
        --from node:20-alpine \\
        --cmd "node /app/server.js" \\
        --env NODE_ENV=production \\
        --output images/node-app

      # Python Flask app
      mix fc.build \\
        --dockerfile ./Dockerfile \\
        --cmd "python app.py" \\
        --env FLASK_ENV=production \\
        --env PORT=8080 \\
        --output images/flask-app

      # Static Nginx server
      mix fc.build \\
        --from nginx:alpine \\
        --cmd "nginx -g 'daemon off;'" \\
        --output images/nginx

  ## After Building

  Add to config/desired_vms.exs:

      [
        {"my-app", "production", %{
          "kernel" => "images/myapp/vmlinux",
          "rootfs" => "images/myapp/rootfs.ext4",
          "cmd" => ["node", "server.js"],
          "resources" => %{"vcpu" => 2, "mem_mb" => 512},
          "lifecycle" => "service"
        }}
      ]

  Or use via HTTP API:

      curl -X POST http://localhost:8088/vms \\
        -H 'Content-Type: application/json' \\
        -d '{
          "spec": {
            "kernel": "images/myapp/vmlinux",
            "rootfs": "images/myapp/rootfs.ext4",
            "resources": {"vcpu": 2, "mem_mb": 512},
            "lifecycle": "service"
          }
        }'
  """

  use Mix.Task
  require Logger

  @shortdoc "Build microVM images from Docker images"

  @impl Mix.Task
  def run(args) do
    # Start application for dependencies
    Mix.Task.run("app.start")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          dockerfile: :string,
          cmd: :string,
          env: :keep,
          output: :string,
          size: :integer,
          kernel: :string,
          help: :boolean
        ]
      )

    if opts[:help] do
      print_help()
    else
      build(opts)
    end
  end

  defp build(opts) do
    config = parse_opts(opts)

    Mix.shell().info("Building microVM image...")
    Mix.shell().info("")

    case FcExCp.ImageBuilder.build(config) do
      {:ok, output_path} ->
        Mix.shell().info("")
        Mix.shell().info("✓ Image built successfully!")
        Mix.shell().info("")
        print_usage(output_path, config)
        :ok

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("✗ Build failed: #{inspect(reason)}")
        Mix.shell().error("")
        System.halt(1)
    end
  end

  defp parse_opts(opts) do
    env =
      opts
      |> Keyword.get_values(:env)
      |> Enum.map(fn env_str ->
        case String.split(env_str, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    cmd = parse_cmd(opts[:cmd])

    base_config = %{
      cmd: cmd,
      env: env,
      output: opts[:output] || "output",
      rootfs_size_mb: opts[:size] || 512
    }

    # Add kernel if specified
    base_config =
      if opts[:kernel] do
        Map.put(base_config, :kernel, opts[:kernel])
      else
        base_config
      end

    # Add from or dockerfile
    cond do
      opts[:from] ->
        Map.put(base_config, :from, opts[:from])

      opts[:dockerfile] ->
        Map.put(base_config, :dockerfile, opts[:dockerfile])

      true ->
        Mix.shell().error("Error: Must specify either --from or --dockerfile")
        System.halt(1)
    end
  end

  defp parse_cmd(nil), do: []

  defp parse_cmd(cmd_str) do
    # Simple command parsing (handles quoted strings)
    cmd_str
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
  end

  defp print_usage(output_path, config) do
    Mix.shell().info("Image location: #{Path.expand(output_path)}")
    Mix.shell().info("")
    Mix.shell().info("Contents:")
    Mix.shell().info("  vmlinux       - Kernel (#{format_size("#{output_path}/vmlinux")})")

    Mix.shell().info(
      "  rootfs.ext4   - Root filesystem (#{format_size("#{output_path}/rootfs.ext4")})"
    )

    Mix.shell().info("  spec.json     - FcExCp configuration")
    Mix.shell().info("")
    Mix.shell().info("Add to config/desired_vms.exs:")
    Mix.shell().info("")

    spec_example = """
      [
        {"my-app", "production", %{
          "kernel" => "#{output_path}/vmlinux",
          "rootfs" => "#{output_path}/rootfs.ext4",
          "cmd" => #{inspect(config[:cmd])},
          "resources" => %{"vcpu" => 2, "mem_mb" => #{config[:rootfs_size_mb]}},
          "lifecycle" => "service"
        }}
      ]
    """

    Mix.shell().info(spec_example)
  end

  defp format_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        cond do
          size > 1_000_000 -> "#{Float.round(size / 1_000_000, 1)} MB"
          size > 1_000 -> "#{Float.round(size / 1_000, 1)} KB"
          true -> "#{size} bytes"
        end

      _ ->
        "unknown"
    end
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
