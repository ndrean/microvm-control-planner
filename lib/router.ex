defmodule FcExCp.Web.Router do
  use Plug.Router
  alias FcExCp.Manager

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  post "/vms" do
    tenant = conn.body_params["tenant"]

    case Manager.acquire(tenant) do
      {:ok, info} -> json(conn, 201, info)
      {:error, reason} -> json(conn, 503, %{error: inspect(reason)})
    end
  end

  delete "/vms/:id" do
    Manager.release(id)
    send_resp(conn, 204, "")
  end

  get "/vms/:id" do
    case Manager.lookup(id) do
      {:ok, info} -> json(conn, 200, info)
      :error -> send_resp(conn, 404, "")
    end
  end

  get "/stats" do
    json(conn, 200, Manager.stats())
  end

  get "/metrics" do
    metrics = TelemetryMetricsPrometheus.Core.scrape(TelemetryMetricsPrometheus.Core)
    send_resp(conn, 200, metrics)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, status, map) do
    {:ok, body} = Jason.encode(map)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
