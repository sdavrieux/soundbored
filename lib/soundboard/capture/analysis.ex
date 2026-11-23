defmodule Soundboard.Capture.Analysis do
  @moduledoc """
  Cheap loudness analysis of moment PCM, used to trim dead air and to point out
  highlights. An envelope is the mean power of each 20 ms window (0.0 to 1.0).
  Speaker stems are analysed separately so crosstalk can be told apart from one loud voice.
  """

  @window 0.02
  @window_bytes 1920
  # Discord voice is noise-gated, so anything above this is someone speaking.
  @speech_db -42.0
  # Highlights are scored in half-second blocks.
  @block 25
  @min_score 6.0
  @max_highlights 3

  def envelope(pcm), do: envelope(pcm, [])

  defp envelope(<<chunk::binary-size(@window_bytes), rest::binary>>, acc),
    do: envelope(rest, [power(chunk) | acc])

  defp envelope(<<>>, acc), do: Enum.reverse(acc)
  defp envelope(chunk, acc), do: Enum.reverse([power(chunk) | acc])

  defp power(chunk) do
    sum = for <<sample::little-signed-16 <- chunk>>, reduce: 0, do: (acc -> acc + sample * sample)
    sum / max(1, div(byte_size(chunk), 2)) / 1_073_741_824
  end

  @doc "Adds the power of several equally long envelopes, as if they were mixed."
  def combine([]), do: []
  def combine([env]), do: env
  def combine(envs), do: Enum.zip_with(envs, &Enum.sum/1)

  @doc """
  Start and end (seconds) of the speech in an envelope, with a little breathing room,
  or nil when nobody speaks. A lone click is not speech: a window only counts when
  most of the next 100 ms is loud too.
  """
  def speech_bounds(env, duration) do
    active = Enum.map(env, &(db(&1) > @speech_db))

    case first_speech(active) do
      nil ->
        nil

      first ->
        last = first_speech(Enum.reverse(active))
        start = max(0.0, first * @window - 0.25)
        stop = min(duration * 1.0, (length(active) - last) * @window + 0.5)
        {Float.round(start, 2), Float.round(stop, 2)}
    end
  end

  defp first_speech(active) do
    active
    |> Enum.chunk_every(5, 1)
    |> Enum.find_index(fn [head | _] = chunk -> head and Enum.count(chunk, & &1) >= 3 end)
  end

  @doc """
  Up to three moments worth a listen: blocks clearly louder than the clip's usual
  speech, or where several people talk (or laugh) at once. Each comes with a few
  seconds of lead-in so the trim makes sense on its own.
  """
  def highlights(envs, duration) do
    loudness = envs |> combine() |> Enum.chunk_every(@block) |> Enum.map(&db(mean(&1)))
    talking = talking(envs)
    speech = Enum.filter(loudness, &(&1 > @speech_db))

    if length(speech) < 2 do
      []
    else
      median = median(speech)

      loudness
      |> Enum.zip(talking)
      |> Enum.with_index()
      |> Enum.flat_map(&scored_block(&1, median))
      |> regions()
      |> Enum.map(&highlight(&1, duration))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(@max_highlights)
      |> Enum.sort_by(& &1.start)
    end
  end

  defp scored_block({{level, voices}, index}, median) do
    score = level - median + 4 * (voices - 1)

    if level > @speech_db and score >= @min_score,
      do: [%{index: index, score: score, loud: level - median >= @min_score, voices: voices}],
      else: []
  end

  # How many speakers are active for a good part of each block.
  defp talking(envs) do
    envs
    |> Enum.map(fn env -> env |> Enum.chunk_every(@block) |> Enum.map(&speaking/1) end)
    |> Enum.zip_with(&Enum.sum/1)
  end

  defp speaking(chunk),
    do: if(Enum.count(chunk, &(db(&1) > @speech_db)) * 10 >= length(chunk) * 3, do: 1, else: 0)

  # Neighbouring loud blocks (one quiet block apart at most) are one highlight.
  defp regions(blocks) do
    blocks
    |> Enum.chunk_while(
      [],
      fn
        block, [] -> {:cont, [block]}
        block, [prev | _] = acc when block.index - prev.index <= 2 -> {:cont, [block | acc]}
        block, acc -> {:cont, Enum.reverse(acc), [block]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp highlight(blocks, duration) do
    peak = Enum.max_by(blocks, & &1.score)
    block_seconds = @block * @window

    %{
      start: Float.round(max(0.0, hd(blocks).index * block_seconds - 2.0), 2),
      stop:
        Float.round(min(duration * 1.0, (List.last(blocks).index + 1) * block_seconds + 1.0), 2),
      at: Float.round(peak.index * block_seconds, 2),
      score: peak.score,
      loud: Enum.any?(blocks, & &1.loud),
      voices: blocks |> Enum.map(& &1.voices) |> Enum.max()
    }
  end

  defp db(power), do: 10 * :math.log10(max(power, 1.0e-10))
  defp mean(values), do: Enum.sum(values) / max(1, length(values))

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
