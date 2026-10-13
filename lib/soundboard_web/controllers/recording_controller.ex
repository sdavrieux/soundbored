defmodule SoundboardWeb.RecordingController do
  use SoundboardWeb, :controller
  alias Soundboard.Capture.Storage

  def preview(conn, %{"name" => name}) do
    with {:ok, path} <- Storage.download_path(name), {:ok, %{size: size}} <- File.stat(path) do
      conn =
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_content_type("audio/wav")

      case get_req_header(conn, "range") do
        [] -> send_file(conn, 200, path)
        [range] -> send_range(conn, path, size, range)
        _ -> invalid_range(conn, size)
      end
    else
      _ -> send_resp(conn, 404, "Recording not found")
    end
  end

  defp send_range(conn, path, size, range) do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, range) do
      [_, "", suffix] when suffix != "" ->
        count = min(String.to_integer(suffix), size)
        range_response(conn, path, size, size - count, size - 1)

      [_, first, last] when first != "" ->
        start = String.to_integer(first)
        stop = if last == "", do: size - 1, else: min(String.to_integer(last), size - 1)
        range_response(conn, path, size, start, stop)

      _ ->
        invalid_range(conn, size)
    end
  end

  defp range_response(conn, path, size, start, stop)
       when start >= 0 and start <= stop and start < size do
    conn
    |> put_resp_header("content-range", "bytes #{start}-#{stop}/#{size}")
    |> send_file(206, path, start, stop - start + 1)
  end

  defp range_response(conn, _, size, _, _), do: invalid_range(conn, size)

  defp invalid_range(conn, size),
    do:
      conn
      |> put_resp_header("content-range", "bytes */#{size}")
      |> send_resp(416, "Invalid range")

  def show(conn, %{"name" => name}) do
    case Storage.download_path(name) do
      {:ok, path} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> send_download({:file, path}, filename: name, content_type: "audio/wav")

      {:error, :not_found} ->
        send_resp(conn, 404, "Recording not found")
    end
  end
end
