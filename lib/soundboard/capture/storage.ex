defmodule Soundboard.Capture.Storage do
  @moduledoc """
  Private recording storage. Only generated WAV filenames may be downloaded.
  No recordings are stored in the public uploads directory.
  """
  alias Soundboard.Capture.Ogg
  @filename ~r/\Amoment-\d{8}T\d{6}Z-[a-f0-9]{16}\.wav\z/
  @max_clips 200

  def directory do
    Application.get_env(:soundboard, :recordings_dir, Path.expand("priv/recordings"))
  end

  def list do
    case File.ls(directory()) do
      {:ok, names} -> names |> Enum.filter(&valid_name?/1) |> Enum.sort(:desc)
      _ -> []
    end
  end

  def download_path(name) do
    path = Path.join(directory(), name)

    with true <- valid_name?(name),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  def save(snapshot) do
    with ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         :ok <- prepare_directory(),
         true <- length(list()) < @max_clips do
      name =
        "moment-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")}-#{random_id()}.wav"

      work = Path.join(directory(), ".export-#{random_id()}")

      with :ok <- File.mkdir(work), :ok <- File.chmod(work, 0o700) do
        try do
          export(ffmpeg, snapshot, work, name)
        after
          File.rm_rf(work)
        end
      end
    else
      nil -> {:error, :ffmpeg_missing}
      false -> {:error, :storage_full}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp prepare_directory do
    path = Path.expand(directory())
    static = Path.expand("priv/static")

    if path == static or String.starts_with?(path, static <> "/") do
      {:error, :public_directory}
    else
      with :ok <- File.mkdir_p(path),
           {:ok, %{type: :directory}} <- File.lstat(path) do
        File.chmod(path, 0o700)
      end
    end
  end

  defp export(ffmpeg, snapshot, work, name) do
    inputs =
      snapshot.frames
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.with_index(1)
      |> Enum.map(fn {{_speaker, frames}, index} ->
        path = Path.join(work, "track-#{index}.ogg")
        File.write!(path, Ogg.stream(frames, snapshot.start, index))
        ["-protocol_whitelist", "file,pipe", "-i", path]
      end)

    duration = max(0.02, (snapshot.stop - snapshot.start) / 1000)
    output = Path.join(work, "mix.wav")

    filter =
      "amix=inputs=#{length(inputs)}:normalize=0:duration=longest,alimiter=limit=0.95:level=false:latency=true,apad"

    args =
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror"] ++
        List.flatten(inputs) ++
        [
          "-filter_complex",
          filter,
          "-t",
          to_string(duration),
          "-ar",
          "48000",
          "-ac",
          "1",
          "-c:a",
          "pcm_s16le",
          output
        ]

    with :ok <- run_ffmpeg(ffmpeg, args),
         :ok <- File.chmod(output, 0o600),
         :ok <- File.rename(output, Path.join(directory(), name)) do
      {:ok, name}
    else
      _ -> {:error, :export_failed}
    end
  end

  defp run_ffmpeg(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    deadline = System.monotonic_time(:millisecond) + 60_000
    await_ffmpeg(port, deadline)
  end

  defp await_ffmpeg(port, deadline) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, _}} -> await_ffmpeg(port, deadline)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _}} -> {:error, :export_failed}
    after
      timeout ->
        Port.close(port)
        {:error, :export_timeout}
    end
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(@filename, name)
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
