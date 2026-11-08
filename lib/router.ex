# lib/fc_ex_cp/web/router.ex  (COHERENT WITH PoolManager.attach(job_id))
defmodule FcExCp.Web.Router do
  use Plug.Router
  alias FcExCp.{PoolManager, DesiredStateStore}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # 1 job = 1 VM
  # Body accepted:
  # - {"spec":{...}}  (vm_id auto-generated)
  # - {"job_id":"job_1","spec":{...}}
  # - {"vm_id":"job_1","tenant":"job_1","spec":{...}}
  # - {"tenant":"job_1","spec":{...}}  (back-compat)
  post "/vms" do
    job_id =
      conn.body_params["job_id"] || conn.body_params["vm_id"] || conn.body_params["tenant"] ||
        generate_vm_id()

    tenant = conn.body_params["tenant"] || job_id
    spec = conn.body_params["spec"] || %{}

    case {job_id, tenant, spec} do
      {id, t, s}
      when is_binary(id) and byte_size(id) > 0 and is_binary(t) and byte_size(t) > 0 and is_map(s) ->
        :ok = DesiredStateStore.put(id, t, spec)

        case PoolManager.attach(id, spec) do
          {:ok, info} ->
            # Provisioned from warm capacity or a cold boot.
            json(conn, 201, info)

          {:error, :capacity_exhausted} ->
            json(conn, 202, %{
              job_id: id,
              status: "accepted",
              message: "VM scheduled, reconciler will provision when capacity is available"
            })

          {:error, reason} ->
            # Desired state is retained so the reconciler can retry.
            json(conn, 503, %{error: inspect(reason)})
        end

      _ ->
        json(conn, 400, %{
          error: "job_id and tenant must be non-empty strings; spec must be an object"
        })
    end
  end

  delete "/vms/:id" do
    :ok = DesiredStateStore.delete(id)
    PoolManager.detach(id)
    send_resp(conn, 204, "")
  end

  get "/vms/:id" do
    case PoolManager.lookup(id) do
      {:ok, info} -> json(conn, 200, info)
      :error -> send_resp(conn, 404, "")
    end
  end

  get "/stats" do
    json(conn, 200, PoolManager.stats())
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
    # body = :json.encode(map) |> IO.iodata_to_binary()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp generate_vm_id do
    "vm-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
