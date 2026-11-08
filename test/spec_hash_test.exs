defmodule FcExCp.SpecHashTest do
  use ExUnit.Case, async: true
  alias FcExCp.SpecHash

  test "config maps and JSON maps produce the same hash including nested values" do
    spec = %{resources: %{vcpu: 2}, env: %{PORT: "4000"}, cmd: ["run", %{flag: true}]}
    json = spec |> Jason.encode!() |> Jason.decode!()
    assert SpecHash.hash(spec) == SpecHash.hash(json)
    refute SpecHash.hash(spec) == SpecHash.hash(Map.put(spec, :rootfs, "different"))
  end
end
