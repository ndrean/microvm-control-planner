defmodule FcExCp.SpecHash do
  @moduledoc """
  Identifies equivalent VM specifications from Elixir config or JSON requests.
  """

  def hash(spec) when is_map(spec) do
    spec
    |> normalize()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value), do: value
end
