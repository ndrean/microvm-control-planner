defmodule FcExCp.SpecHash do
  @moduledoc """
  Generates stable hashes for VM specs to identify identical configurations.
  Two VMs with the same spec should produce the same hash.
  """

  def hash(spec) when is_map(spec) do
    spec
    |> normalize()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end

  defp normalize(spec) do
    # Sort keys to ensure consistent hashing regardless of insertion order
    spec
    |> Enum.sort()
    |> Enum.into(%{})
  end
end
