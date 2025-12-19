defmodule FcExCp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {TelemetryMetricsPrometheus.Core,
       [
         metrics: FcExCp.Metrics.metrics()
       ]},
      # Telemetry poller for periodic metric collection
      {:telemetry_poller,
       measurements: [
         {FcExCp.TelemetryPoller, :collect_runtime_metrics, []}
       ],
       period: :timer.seconds(5),
       init_delay: :timer.seconds(60),
       name: :fc_ex_cp_poller},
      # VM registry
      {Registry, keys: :unique, name: FcExCp.Registry},
      # VM supervisor
      {DynamicSupervisor, name: FcExCp.VMSup, strategy: :one_for_one},
      {Task, fn -> FcExCp.Net.ensure_host_network!() end},
      FcExCp.Manager,
      {Plug.Cowboy,
       scheme: :http,
       plug: FcExCp.Web.Router,
       options: [
         ip: FcExCp.Config.listen_ip(),
         port: FcExCp.Config.listen_port()
       ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FcExCp.Supervisor)
  end
end
