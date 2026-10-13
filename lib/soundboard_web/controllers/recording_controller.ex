defmodule SoundboardWeb.RecordingController do
  use SoundboardWeb, :controller
  alias Soundboard.Capture.Storage

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
