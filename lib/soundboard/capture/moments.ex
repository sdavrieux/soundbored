defmodule Soundboard.Capture.Moments do
  @moduledoc "Private moment editing. Only our generated PCM WAV recordings are accepted."
  alias Soundboard.Capture.Storage
  alias Soundboard.{PubSubTopics, Sounds}

  def list do
    Storage.list()
    |> Enum.flat_map(fn name ->
      case get(name) do
        {:ok, moment} -> [moment]
        _ -> []
      end
    end)
  end

  def get(name) do
    with {:ok, path} <- Storage.download_path(name),
         {:ok, format} <- format(path),
         {:ok, stat} <- File.stat(path) do
      metadata = metadata(path)

      {:ok,
       %{
         name: name,
         title: metadata["title"] || default_title(name),
         revision: metadata["revision"] || "#{stat.size}-#{inspect(stat.mtime)}",
         duration: format.size / format.rate
       }}
    end
  end

  def save(name, revision, attrs) do
    locked(name, fn -> edit(name, revision, attrs, &replace_segment/3) end)
  end

  def delete(name, revision) do
    locked(name, fn -> delete_current(name, revision) end)
  end

  def publish(name, revision, attrs, user) do
    locked(name, fn ->
      edit(name, revision, attrs, fn segment, title, _ ->
        publish_segment(segment, title, user)
      end)
    end)
  end

  defp edit(name, revision, attrs, operation) do
    with {:ok, moment} <- current(name, revision),
         {:ok, title, start, stop} <- selection(moment, attrs),
         {:ok, path} <- Storage.download_path(name) do
      with_segment(path, start, stop, fn segment -> operation.(segment, title, path) end)
    end
  end

  defp replace_segment(segment, title, path) do
    with :ok <- write_metadata(path, title), :ok <- File.rename(segment, path) do
      name = Path.basename(path)
      notify(name)
      get(name)
    end
  end

  defp delete_current(name, revision) do
    with {:ok, _} <- current(name, revision),
         {:ok, path} <- Storage.download_path(name),
         :ok <- File.rm(path) do
      File.rm(path <> ".json")
      notify(name)
      :ok
    end
  end

  defp publish_segment(segment, title, user) do
    user
    |> Sounds.new_create_request(%{
      source_type: "local",
      name: title,
      upload: %{path: segment, filename: "moment.wav"},
      tags: ["moments"],
      volume: 100,
      is_join_sound: false,
      is_leave_sound: false
    })
    |> Sounds.create_sound()
  end

  defp current(name, revision) do
    with {:ok, moment} <- get(name) do
      if moment.revision == revision, do: {:ok, moment}, else: {:error, :stale}
    end
  end

  defp selection(moment, attrs) do
    title = String.trim(to_string(attrs["title"] || ""))

    with true <- String.length(title) in 1..100,
         {start, ""} <- Float.parse(to_string(attrs["start"])),
         {stop, ""} <- Float.parse(to_string(attrs["stop"])),
         true <- start >= 0 and stop - start >= 0.05 and stop <= moment.duration + 0.001 do
      {:ok, title, start, min(stop, moment.duration)}
    else
      _ -> {:error, :invalid_selection}
    end
  end

  # Parse RIFF chunks instead of assuming that FFmpeg's metadata is always the same size.
  defp format(path) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, 12) do
        <<"RIFF", _::little-32, "WAVE">> -> chunks(io, nil)
        _ -> {:error, :invalid_audio}
      end
    end)
    |> unwrap()
  end

  defp chunks(io, rate) do
    case IO.binread(io, 8) do
      <<"fmt ", size::little-32>> when size >= 16 and size <= 1024 ->
        read_format(io, size)

      <<"data", size::little-32>> when not is_nil(rate) ->
        {:ok, offset} = :file.position(io, :cur)
        {:ok, %{offset: offset, size: size, rate: rate}}

      <<_, _, _, _, size::little-32>> when size < 65_536 ->
        :file.position(io, {:cur, size + rem(size, 2)})
        chunks(io, rate)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp read_format(io, size) do
    case IO.binread(io, size) do
      <<1::little-16, 1::little-16, 48_000::little-32, 96_000::little-32, 2::little-16,
        16::little-16, _::binary>> ->
        if rem(size, 2) == 1, do: IO.binread(io, 1)
        chunks(io, 96_000)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error

  defp with_segment(path, start, stop, operation) do
    work = Path.join(Storage.directory(), ".trim-#{id()}")

    with :ok <- File.mkdir(work), :ok <- File.chmod(work, 0o700) do
      segment = Path.join(work, "segment.wav")

      try do
        with :ok <- copy_segment(path, segment, start, stop), do: operation.(segment)
      after
        File.rm_rf(work)
      end
    end
  end

  defp copy_segment(path, output, start, stop) do
    with {:ok, info} <- format(path) do
      first = trunc(start * 48_000) * 2
      size = min(trunc(stop * 48_000) * 2, info.size) - first

      header =
        <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
          48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
          size::little-32>>

      File.open(path, [:read, :binary], fn source ->
        write_segment(source, output, header, info.offset + first, size)
      end)
      |> unwrap()
    end
  end

  defp write_segment(source, output, header, offset, size) do
    File.open(output, [:write, :binary, :exclusive], fn target ->
      :ok = File.chmod(output, 0o600)
      :ok = IO.binwrite(target, header)
      {:ok, _} = :file.position(source, offset)
      copy_bytes(source, target, size)
    end)
    |> unwrap()
  end

  defp copy_bytes(_, _, 0), do: :ok

  defp copy_bytes(source, target, remaining) do
    count = min(remaining, 65_536)

    case IO.binread(source, count) do
      data when is_binary(data) and byte_size(data) == count ->
        with :ok <- IO.binwrite(target, data), do: copy_bytes(source, target, remaining - count)

      _ ->
        {:error, :invalid_audio}
    end
  end

  defp metadata(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path <> ".json"),
         true <- size < 4096,
         {:ok, data} <- File.read(path <> ".json"),
         {:ok, result} when is_map(result) <- Jason.decode(data),
         do: result,
         else: (_ -> %{})
  end

  defp write_metadata(path, title) do
    temp = path <> ".#{id()}.json"

    try do
      with :ok <- File.write(temp, Jason.encode!(%{title: title, revision: id()}), [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           do: File.rename(temp, path <> ".json")
    after
      File.rm(temp)
    end
  end

  defp default_title(name),
    do: "Moment #{String.slice(name, 7, 8)} · #{String.slice(name, 16, 6)}"

  defp id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp locked(name, operation),
    do: :global.trans({{__MODULE__, name}, self()}, operation, [node()])

  defp notify(name), do: PubSubTopics.broadcast_desk({:moments_updated, name})
end
