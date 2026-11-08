defmodule FcExCp.RouterTest do
  use FcExCp.ControlPlaneCase, async: false
  import Plug.Test

  alias FcExCp.Web.Router

  defp request(method, path, body \\ nil) do
    conn = conn(method, path, if(body, do: Jason.encode!(body), else: nil))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    Router.call(conn, Router.init([]))
  end

  test "POST cold provisions a workload and GET returns it" do
    response = request(:post, "/vms", %{job_id: "api", tenant: "customer", spec: spec()})
    assert response.status == 201
    assert %{"status" => "running", "tenant" => "customer"} = Jason.decode!(response.resp_body)
    assert request(:get, "/vms/api").status == 200
    assert PoolManager.stats().summary == %{total_jobs: 1, total_warm: 0}
  end

  test "POST replaces an existing workload's specification" do
    first = request(:post, "/vms", %{job_id: "api", spec: spec()})
    updated = spec(%{"rootfs" => "new-rootfs"})
    second = request(:post, "/vms", %{job_id: "api", spec: updated})
    assert second.status == 201
    assert Jason.decode!(first.resp_body)["id"] != Jason.decode!(second.resp_body)["id"]
    assert Jason.decode!(second.resp_body)["specs"] == updated
    assert child_count() == 1
  end

  @tag max_vms: 1
  test "POST at capacity returns 202 and eventually provisions after deletion" do
    assert request(:post, "/vms", %{job_id: "first", spec: spec()}).status == 201
    response = request(:post, "/vms", %{job_id: "next", spec: spec()})
    assert response.status == 202
    assert Jason.decode!(response.resp_body)["status"] == "accepted"
    assert {:ok, _} = DesiredStateStore.get("next")
    assert request(:delete, "/vms/first").status == 204
    Reconciler.reconcile()
    assert request(:get, "/vms/next").status == 200
    assert request(:get, "/vms/first").status == 404
  end

  test "invalid spec returns 400 without persisting or crashing" do
    response = request(:post, "/vms", %{job_id: "invalid", spec: ["not", "a", "map"]})
    assert response.status == 400
    assert DesiredStateStore.list() == %{}
    assert Process.alive?(Process.whereis(PoolManager))
  end

  test "failed boot returns 503 and retains desired state for retry" do
    response = request(:post, "/vms", %{job_id: "broken", spec: spec(%{"boot_error" => true})})
    assert response.status == 503
    assert {:ok, _} = DesiredStateStore.get("broken")
    assert child_count() == 0
  end
end
