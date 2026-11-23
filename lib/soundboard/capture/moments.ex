defmodule Soundboard.Capture.Moments do
  @moduledoc """
  Private moment editing. Only our generated PCM WAV recordings are accepted.
  Moments with several speakers keep one stem per speaker so people can be left
  out of the mix later; stems are trimmed together with the mix.
  """
  alias Soundboard.Capture.{Analysis, Storage, Wav}
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
         {:ok, format} <- Wav.format(path),
         {:ok, stat} <- File.stat(path) do
      metadata = metadata(path)
      speakers = speakers(name, metadata)
      ids = Enum.map(speakers, & &1.id)

      {:ok,
       %{
         name: name,
         title: metadata["title"] || default_title(name),
         titled: is_binary(metadata["title"]),
         recorded_at: recorded_at(name),
         tags: clean_tags(metadata["tags"]),
         revision: metadata["revision"] || "#{stat.size}-#{inspect(stat.mtime)}",
         duration: format.size / format.rate,
         speakers: speakers,
         muted: Enum.filter(List.wrap(metadata["muted"]), &(&1 in ids))
       }}
    end
  end

  # Stems are numbered by who spoke first; names come from the save, when known.
  defp speakers(name, metadata) do
    folder = Storage.stems_path(name)
    names = if is_list(metadata["speakers"]), do: metadata["speakers"], else: []

    with {:ok, %{type: :directory}} <- File.lstat(folder),
         {:ok, files} <- File.ls(folder) do
      count = Enum.count(files, &Regex.match?(~r/\A\d+\.wav\z/, &1))

      speakers =
        Enum.take_while(
          1..count//1,
          &match?({:ok, %{type: :regular}}, File.lstat(stem(name, &1)))
        )
        |> Enum.map(fn index ->
          %{id: to_string(index), name: speaker_name(Enum.at(names, index - 1), index)}
        end)

      if length(speakers) > 1, do: speakers, else: []
    else
      _ -> []
    end
  end

  defp speaker_name(name, index) when is_binary(name) do
    case String.trim(name) do
      "" -> "Speaker #{index}"
      name -> String.slice(name, 0, 40)
    end
  end

  defp speaker_name(_, index), do: "Speaker #{index}"

  defp stem(name, id), do: Path.join(Storage.stems_path(name), "#{id}.wav")

  @doc "Speakers currently heard in the saved mix."
  def active_speakers(moment), do: Enum.map(moment.speakers, & &1.id) -- moment.muted

  @doc "Tags used by any saved moment, most used first."
  def all_tags(moments \\ list()) do
    moments
    |> Enum.flat_map(& &1.tags)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Sets the name and adds tags without touching the audio. Used right after a save,
  so a blank title keeps the current one and tags are merged, not replaced.
  """
  def label(name, attrs) do
    locked(name, fn ->
      with {:ok, moment} <- get(name),
           {:ok, path} <- Storage.download_path(name),
           tags = clean_tags(moment.tags ++ clean_tags(attrs["tags"])),
           :ok <-
             write_metadata(
               path,
               Map.merge(
                 %{"title" => label_title(moment, attrs["title"]), "tags" => tags},
                 speaker_names(attrs["speakers"])
               )
             ) do
        notify(name)
        get(name)
      end
    end)
  end

  defp speaker_names(names) when is_list(names),
    do: %{"speakers" => Enum.map(names, &if(is_binary(&1), do: String.slice(&1, 0, 40)))}

  defp speaker_names(_), do: %{}

  defp label_title(moment, title) do
    case String.trim(to_string(title || "")) do
      "" -> if moment.titled, do: moment.title
      title -> String.slice(title, 0, 100)
    end
  end

  def save(name, revision, attrs) do
    locked(name, fn -> edit(name, revision, attrs, &replace_segment/2) end)
  end

  def delete(name, revision) do
    locked(name, fn -> delete_current(name, revision) end)
  end

  def publish(name, revision, attrs, user) do
    locked(name, fn ->
      edit(name, revision, attrs, fn
        _segment, %{title: nil} -> {:error, :untitled}
        segment, edit -> publish_segment(segment, edit, user)
      end)
    end)
  end

  defp edit(name, revision, attrs, operation) do
    with {:ok, moment} <- current(name, revision),
         {:ok, title, start, stop} <- selection(moment, attrs),
         {:ok, chosen} <- chosen_speakers(moment, attrs["speakers"]),
         {:ok, path} <- Storage.download_path(name) do
      edit = %{
        moment: moment,
        path: path,
        title: title,
        tags: clean_tags(attrs["tags"]),
        start: start,
        stop: stop,
        chosen: chosen
      }

      in_work(&edit_in(&1, edit, operation))
    end
  end

  defp edit_in(work, edit, operation) do
    segment = Path.join(work, "segment.wav")

    with {:ok, source} <- source(edit.moment, edit.path, edit.chosen, work),
         :ok <- Wav.copy_segment(source, segment, edit.start, edit.stop) do
      operation.(segment, Map.put(edit, :work, work))
    end
  end

  # No speaker list keeps whoever is in the mix now; an empty one is a mistake.
  defp chosen_speakers(%{speakers: []}, _), do: {:ok, []}
  defp chosen_speakers(moment, nil), do: {:ok, active_speakers(moment)}

  defp chosen_speakers(moment, ids) when is_list(ids) do
    case Enum.filter(Enum.map(moment.speakers, & &1.id), &(&1 in ids)) do
      [] -> {:error, :no_speakers}
      chosen -> {:ok, chosen}
    end
  end

  defp chosen_speakers(_, _), do: {:error, :no_speakers}

  defp source(moment, path, chosen, work) do
    if chosen == [] or chosen == active_speakers(moment) do
      {:ok, path}
    else
      output = Path.join(work, "speakers.wav")

      with :ok <- Storage.mix(Enum.map(chosen, &stem(moment.name, &1)), output),
           do: {:ok, output}
    end
  end

  defp replace_segment(segment, edit) do
    metadata = %{"title" => edit.title, "tags" => edit.tags}

    metadata =
      if edit.chosen == [],
        do: metadata,
        else: Map.put(metadata, "muted", Enum.map(edit.moment.speakers, & &1.id) -- edit.chosen)

    with :ok <- trim_stems(edit),
         :ok <- write_metadata(edit.path, metadata),
         :ok <- File.rename(segment, edit.path) do
      name = Path.basename(edit.path)
      notify(name)
      get(name)
    end
  end

  defp trim_stems(%{start: start, stop: stop, moment: moment})
       when start == 0 and stop >= moment.duration - 0.001,
       do: :ok

  defp trim_stems(edit) do
    Enum.reduce_while(edit.moment.speakers, :ok, fn %{id: id}, :ok ->
      trimmed = Path.join(edit.work, "stem-#{id}.wav")
      original = stem(edit.moment.name, id)

      with :ok <- Wav.copy_segment(original, trimmed, edit.start, edit.stop),
           :ok <- File.rename(trimmed, original) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp delete_current(name, revision) do
    with {:ok, _} <- current(name, revision),
         {:ok, path} <- Storage.download_path(name),
         :ok <- File.rm(path) do
      File.rm(path <> ".json")
      File.rm_rf(Storage.stems_path(name))
      notify(name)
      :ok
    end
  end

  defp publish_segment(segment, %{title: title, tags: tags}, user) do
    user
    |> Sounds.new_create_request(%{
      source_type: "local",
      name: title,
      upload: %{path: segment, filename: "moment.wav"},
      tags: Enum.uniq(["moments" | tags]),
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
    # A blank name keeps the dated default; only publishing needs a real name.
    title = String.trim(to_string(attrs["title"] || ""))

    with true <- String.length(title) <= 100,
         {start, ""} <- Float.parse(to_string(attrs["start"])),
         {stop, ""} <- Float.parse(to_string(attrs["stop"])),
         true <- start >= 0 and stop - start >= 0.05 and stop <= moment.duration + 0.001 do
      {:ok, if(title != "", do: title), start, min(stop, moment.duration)}
    else
      _ -> {:error, :invalid_selection}
    end
  end

  defp in_work(operation) do
    work = Path.join(Storage.directory(), ".edit-#{id()}")

    with :ok <- File.mkdir(work), :ok <- File.chmod(work, 0o700) do
      try do
        operation.(work)
      after
        File.rm_rf(work)
      end
    end
  end

  @previews 20

  @doc """
  A WAV of the moment with only the chosen speakers, for listening before saving.
  Mixes are cached per revision and selection; only the latest few are kept.
  """
  def preview(name, ids) do
    with {:ok, moment} <- get(name),
         {:ok, path} <- Storage.download_path(name),
         {:ok, chosen} <- chosen_speakers(moment, ids) do
      if chosen == [] or chosen == active_speakers(moment),
        do: {:ok, path},
        else: cached_mix(moment, chosen)
    end
  end

  defp cached_mix(moment, chosen) do
    folder = Path.join(Storage.directory(), ".previews")
    key = :crypto.hash(:sha256, Enum.join([moment.name, moment.revision | chosen], "\n"))
    output = Path.join(folder, "#{Base.encode16(key, case: :lower) |> String.slice(0, 32)}.wav")

    with :ok <- File.mkdir_p(folder), :ok <- File.chmod(folder, 0o700) do
      case File.lstat(output) do
        {:ok, %{type: :regular}} ->
          {:ok, output}

        _ ->
          temp = Path.join(folder, ".#{id()}.wav")

          try do
            with :ok <- Storage.mix(Enum.map(chosen, &stem(moment.name, &1)), temp),
                 :ok <- File.chmod(temp, 0o600),
                 :ok <- File.rename(temp, output) do
              prune_previews(folder)
              {:ok, output}
            end
          after
            File.rm(temp)
          end
      end
    end
  end

  defp prune_previews(folder) do
    folder
    |> File.ls!()
    |> Enum.map(&Path.join(folder, &1))
    |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)
    |> Enum.drop(@previews)
    |> Enum.each(&File.rm/1)
  rescue
    _ -> :ok
  end

  @doc """
  Loudness envelopes for a moment: one per speaker stem, or a single `"all"` one for
  recordings without stems. Feed them to `highlights/3` and `speech_bounds/3`.
  """
  def analyze(name) do
    with {:ok, moment} <- get(name), {:ok, path} <- Storage.download_path(name) do
      sources =
        if moment.speakers == [],
          do: [{"all", path}],
          else: Enum.map(moment.speakers, &{&1.id, stem(name, &1.id)})

      with {:ok, envelopes} <- read_envelopes(sources) do
        {:ok,
         %{name: name, revision: moment.revision, duration: moment.duration, envelopes: envelopes}}
      end
    end
  end

  defp read_envelopes(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn {id, source}, {:ok, envelopes} ->
      case Wav.read(source) do
        {:ok, pcm} -> {:cont, {:ok, Map.put(envelopes, id, Analysis.envelope(pcm))}}
        error -> {:halt, error}
      end
    end)
  end

  def highlights(analysis, chosen),
    do: Analysis.highlights(envelopes(analysis, chosen), analysis.duration)

  def speech_bounds(analysis, chosen),
    do:
      analysis
      |> envelopes(chosen)
      |> Analysis.combine()
      |> Analysis.speech_bounds(analysis.duration)

  defp envelopes(%{envelopes: %{"all" => env}}, _), do: [env]

  defp envelopes(%{envelopes: envelopes}, chosen),
    do: for(id <- chosen, Map.has_key?(envelopes, id), do: envelopes[id])

  defp metadata(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path <> ".json"),
         true <- size < 16_384,
         {:ok, data} <- File.read(path <> ".json"),
         {:ok, result} when is_map(result) <- Jason.decode(data),
         do: result,
         else: (_ -> %{})
  end

  defp write_metadata(path, changes) do
    temp = path <> ".#{id()}.json"

    data =
      path
      |> metadata()
      |> Map.merge(changes)
      |> Map.put("revision", id())
      |> Jason.encode!()

    try do
      with :ok <- File.write(temp, data, [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           do: File.rename(temp, path <> ".json")
    after
      File.rm(temp)
    end
  end

  @max_tags 12

  @doc "Lowercased, trimmed, unique tags from a list or a comma-separated string."
  def clean_tags(tags) when is_binary(tags), do: tags |> String.split(",") |> clean_tags()

  def clean_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> String.slice(0, 30)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end

  def clean_tags(_), do: []

  # The browser shows untitled moments in local time; this is the UTC fallback.
  defp default_title(name) do
    case recorded_at(name) do
      nil -> "Untitled moment"
      iso -> "Moment #{String.slice(iso, 0, 10)} #{String.slice(iso, 11, 5)} UTC"
    end
  end

  defp recorded_at(
         <<"moment-", y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2,
           s::binary-2, "Z", _::binary>>
       ),
       do: "#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z"

  defp recorded_at(_), do: nil

  defp id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp locked(name, operation),
    do: :global.trans({{__MODULE__, name}, self()}, operation, [node()])

  defp notify(name), do: PubSubTopics.broadcast_desk({:moments_updated, name})
end
