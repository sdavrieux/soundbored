defmodule Soundboard.Capture.Storage do
  @moduledoc """
  Private recording storage. Only generated WAV filenames may be downloaded.
  No recordings are stored in the public uploads directory.
  """
  alias Soundboard.Capture.{Analysis, Buffer, Ogg, Wav}
  @filename ~r/\Amoment-\d{8}T\d{6}Z-[a-f0-9]{16}\.wav\z/
  @max_clips 200
  @limiter "alimiter=limit=0.95:level=false:latency=true"

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

  @doc "Folder holding one WAV per speaker (`1.wav`, `2.wav`, ...) when a moment has several."
  def stems_path(name), do: Path.join(directory(), name <> ".stems")

  @doc "Generates the filename a save will use, so the operator can name it while it exports."
  def new_name,
    do: "moment-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")}-#{random_id()}.wav"

  def save(snapshot, name \\ new_name()) do
    with true <- valid_name?(name),
         ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         :ok <- prepare_directory(),
         true <- length(list()) < @max_clips do
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
      false -> if valid_name?(name), do: {:error, :storage_full}, else: {:error, :invalid_name}
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

  # Each speaker is decoded to its own stem next to the mix, so the editor can drop
  # someone later. Leading and trailing dead air is trimmed from all of them alike.
  defp export(ffmpeg, snapshot, work, name) do
    speakers = Buffer.speakers(snapshot.frames)
    groups = Enum.group_by(snapshot.frames, &elem(&1, 1))
    duration = to_string(max(0.02, (snapshot.stop - snapshot.start) / 1000))
    stems? = length(speakers) > 1

    inputs =
      speakers
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {speaker, index} ->
        path = Path.join(work, "track-#{index}.ogg")
        File.write!(path, Ogg.stream(groups[speaker], snapshot.start, index))
        ["-protocol_whitelist", "file,pipe", "-i", path]
      end)

    tracks =
      for index <- 0..(length(speakers) - 1)//1 do
        split = if stems?, do: ",asplit=2[m#{index}][s#{index}]", else: "[m#{index}]"
        "[#{index}:a]apad=whole_dur=#{duration},atrim=0:#{duration}" <> split
      end

    mix_inputs = Enum.map_join(0..(length(speakers) - 1)//1, &"[m#{&1}]")

    filter =
      Enum.join(
        tracks ++
          [
            "#{mix_inputs}amix=inputs=#{length(speakers)}:normalize=0:duration=longest,#{@limiter}[mix]"
          ],
        ";"
      )

    mix = Path.join(work, "mix.wav")
    stems = for index <- 1..length(speakers)//1, stems?, do: Path.join(work, "stem-#{index}.wav")

    outputs =
      ["-map", "[mix]" | pcm_output(duration, mix)] ++
        Enum.flat_map(Enum.with_index(stems), fn {stem, index} ->
          ["-map", "[s#{index}]" | pcm_output(duration, stem)]
        end)

    args =
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror"] ++
        inputs ++ ["-filter_complex", filter] ++ outputs

    with :ok <- run_ffmpeg(ffmpeg, args),
         {:ok, pcm} <- Wav.read(mix),
         {start, stop} = speech(pcm, String.to_float(duration)),
         :ok <- place_stems(stems, work, name, start, stop),
         final = Path.join(work, "final.wav"),
         :ok <- Wav.copy_segment(mix, final, start, stop),
         :ok <- File.rename(final, Path.join(directory(), name)) do
      {:ok, name}
    else
      _ ->
        File.rm_rf(stems_path(name))
        {:error, :export_failed}
    end
  end

  defp pcm_output(duration, path),
    do: ["-t", duration, "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", path]

  defp speech(pcm, duration) do
    case pcm |> Analysis.envelope() |> Analysis.speech_bounds(duration) do
      nil -> {0.0, duration}
      bounds -> bounds
    end
  end

  defp place_stems([], _, _, _, _), do: :ok

  defp place_stems(stems, work, name, start, stop) do
    folder = Path.join(work, "stems")

    with :ok <- File.mkdir(folder),
         :ok <- File.chmod(folder, 0o700),
         :ok <- copy_stems(stems, folder, start, stop) do
      File.rename(folder, stems_path(name))
    end
  end

  defp copy_stems(stems, folder, start, stop) do
    stems
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {stem, index}, :ok ->
      case Wav.copy_segment(stem, Path.join(folder, "#{index}.wav"), start, stop) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Mixes WAV files the same way an export does."
  def mix(paths, output) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, :ffmpeg_missing}

      ffmpeg ->
        run_ffmpeg(
          ffmpeg,
          ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror"] ++
            Enum.flat_map(paths, &["-i", &1]) ++
            [
              "-filter_complex",
              "amix=inputs=#{length(paths)}:normalize=0:duration=longest,#{@limiter}",
              "-ar",
              "48000",
              "-ac",
              "1",
              "-c:a",
              "pcm_s16le",
              output
            ]
        )
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
