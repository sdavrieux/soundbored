defmodule SoundboardWeb.SoundDownloadController do
  @moduledoc """
  Downloads the sounds picked in the grid's select mode: one sound comes back
  as its audio file, several come back as one zip so phones get a single download.
  """
  use SoundboardWeb, :controller

  import Ecto.Query

  alias Soundboard.{Repo, Sound, UploadsPath}

  @max_sounds 500

  def show(conn, %{"ids" => ids}) when is_binary(ids) do
    case downloadable_files(parse_ids(ids)) do
      [] -> send_resp(conn, 404, "None of the selected sounds have a file to download")
      [{name, path}] -> send_download(conn, {:file, path}, filename: name)
      files -> send_zip(conn, files)
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "No sounds selected")

  defp parse_ids(ids) do
    ids
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn id ->
      case Integer.parse(String.trim(id)) do
        {int, ""} -> [int]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_sounds)
  end

  # Sounds that only link to a remote URL have no file here, so they are skipped.
  defp downloadable_files([]), do: []

  defp downloadable_files(ids) do
    from(s in Sound, where: s.id in ^ids and s.source_type == "local", select: s.filename)
    |> Repo.all()
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.flat_map(fn filename ->
      with {:ok, path} <- UploadsPath.safe_joined_path(filename),
           true <- File.regular?(path) do
        [{filename, path}]
      else
        _ -> []
      end
    end)
  end

  defp send_zip(conn, files) do
    zip_path =
      Path.join(System.tmp_dir!(), "sounds-#{System.unique_integer([:positive])}.zip")

    entries = Enum.map(files, fn {name, _path} -> String.to_charlist(name) end)

    # Audio is already compressed, so store the files as they are.
    {:ok, _} =
      :zip.create(String.to_charlist(zip_path), entries,
        cwd: String.to_charlist(UploadsPath.dir()),
        uncompress: :all
      )

    try do
      send_download(conn, {:file, zip_path},
        filename: "soundboard-#{length(files)}-sounds.zip",
        content_type: "application/zip"
      )
    after
      File.rm(zip_path)
    end
  end
end
