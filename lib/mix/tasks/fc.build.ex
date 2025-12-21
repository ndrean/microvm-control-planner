defmodule Mix.Tasks.Fc.Build do
  @moduledoc """
  Build microVM images from Docker images.

  ## Philosophy

  Start with Docker - leverage the entire container ecosystem!
  1. Find/build a Docker image
  2. Test: `docker run your-image`
  3. Convert: `mix fc.build --from your-image`
  4. Run as microVM!

  ## Usage

      # Simplest - use image defaults
      mix fc.build --from nginx:alpine

      # Override command
      mix fc.build --from node:20-alpine --cmd "node server.js" --output images/myapp

      # Add environment
      mix fc.build --from python:3.11-alpine --env FLASK_ENV=production

  ## Options

    * `--from IMAGE` - Docker image (required)
    * `--cmd COMMAND` - Override container CMD
    * `--env KEY=VALUE` - Environment variable (repeatable)
    * `--output DIR` - Output directory (default: "output")
    * `--size MB` - Rootfs size in MB (default: 512)

  ## Output

  Creates:
    vmlinux       - Kernel (~8MB for Alpine)
    rootfs.ext4   - Root filesystem
    spec.json     - FcExCp config

  ## Examples

      # Node.js app
      mix fc.build \\
        --from node:20-alpine \\
        --cmd "node server.js" \\
        --env NODE_ENV=production \\
        --output images/node-app

      # Nginx
      mix fc.build --from nginx:alpine --output images/nginx

      # Python Flask
      mix fc.build \\
        --from python:3.11-alpine \\
        --env FLASK_ENV=production \\
        --size 1024 \\
        --output images/flask

  ## After Building

  Add to config/desired_vms.exs:

      [
        {"my-app", "prod", %{
          "kernel" => "images/myapp/vmlinux",
          "rootfs" => "images/myapp/rootfs.ext4",
          "resources" => %{"vcpu" => 2, "mem_mb" => 512},
          "lifecycle" => "service"
        }}
      ]
  """

  use Mix.Task
  require Logger

  @shortdoc "Build microVM images from Docker images"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          cmd: :string,
          env: :keep,
          output: :string,
          size: :integer,
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
    unless opts[:from] do
      Mix.shell().error("Error: --from IMAGE is required")
      Mix.shell().info("Example: mix fc.build --from node:20-alpine")
      System.halt(1)
    end

    config = %{
      from: opts[:from],
      cmd: parse_cmd(opts[:cmd]),
      env: parse_env(opts[:env]),
      output: opts[:output] || "output",
      size_mb: opts[:size]
    }

    Mix.shell().info("Building microVM from #{config.from}...")
    Mix.shell().info("")

    case FcExCp.ImageBuilder.build(config) do
      {:ok, path} ->
        Mix.shell().info("")
        Mix.shell().info("✓ Success!")
        print_next_steps(path, config)

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("✗ Failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp parse_cmd(nil), do: nil
  defp parse_cmd(cmd), do: String.split(cmd, " ", trim: true)

  defp parse_env(nil), do: %{}
  defp parse_env(env_list) do
    env_list
    |> Enum.map(fn env ->
      case String.split(env, "=", parts: 2) do
        [k, v] -> {k, v}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp print_next_steps(path, config) do
    Mix.shell().info("")
    Mix.shell().info("Image ready at: #{Path.expand(path)}")
    Mix.shell().info("")
    Mix.shell().info("Add to config/desired_vms.exs:")
    Mix.shell().info("")

    spec = """
      [
        {"my-app", "production", %{
          "kernel" => "#{path}/vmlinux",
          "rootfs" => "#{path}/rootfs.ext4",
          "resources" => %{"vcpu" => 2, "mem_mb" => #{config.size_mb || 512}},
          "lifecycle" => "service"
        }}
      ]
    """

    Mix.shell().info(spec)
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
