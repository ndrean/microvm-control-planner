defmodule FcExCp.Firecracker.HTTP do
  @moduledoc """
  Unix Socket HTTTP client
  This is for Firecracker’s API over /tmp/fc-<id>.sock
  """
  @timeout 5_000

  def put(sock, path, body_map) do
    {:ok, body} = Jason.encode(body_map)

    req =
      "PUT #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n" <>
        body

    request(sock, req)
  end

  def get(sock, path) do
    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Connection: close\r\n" <>
        "\r\n"

    request(sock, req)
  end

  defp request(sock_path, raw_http) do
    with {:ok, sock} <- :socket.open(:local, :stream) do
      try do
        :ok = :socket.connect(sock, %{family: :local, path: sock_path})
        :ok = :socket.send(sock, raw_http)
        recv_all(sock, "")
      after
        :socket.close(sock)
      end
    end
  end

  defp recv_all(sock, acc) do
    case :socket.recv(sock, 0, @timeout) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> parse_response(acc)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [status_line | headers] = String.split(head, "\r\n")
        [_http, status, _reason] = String.split(status_line, " ", parts: 3)

        {:ok,
         %{
           status: String.to_integer(status),
           headers: parse_headers(headers),
           body: body
         }}

      _ ->
        {:error, :bad_http}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [k, v] -> Map.put(acc, String.downcase(k), v)
        _ -> acc
      end
    end)
  end
end
