defmodule Soundboard.Capture.Buffer do
  @moduledoc """
  A bounded, in-memory rolling minute of incoming Opus frames.
  Times are monotonic arrival times; EDA 0.1.3 does not expose RTP timestamps.
  """
  alias Soundboard.Capture.Ogg

  @window_ms 60_000
  @max_bytes 16 * 1024 * 1024
  @max_frames 100_000
  @max_speakers 32
  defstruct frames: :queue.new(), bytes: 0, count: 0

  def prune(buffer, now) do
    case :queue.peek(buffer.frames) do
      {:value, {time, _, packet}} when time < now - @window_ms ->
        {{:value, _}, frames} = :queue.out(buffer.frames)

        prune(
          %{
            buffer
            | frames: frames,
              bytes: buffer.bytes - byte_size(packet),
              count: buffer.count - 1
          },
          now
        )

      _ ->
        buffer
    end
  end

  def push(buffer, now, speaker, packet) when is_binary(speaker) and is_binary(packet) do
    buffer = prune(buffer, now)

    if byte_size(packet) <= 4096 and Ogg.packet_samples(packet) != :error and
         buffer.bytes + byte_size(packet) <= @max_bytes and buffer.count < @max_frames do
      %{
        buffer
        | frames: :queue.in({now, speaker, packet}, buffer.frames),
          bytes: buffer.bytes + byte_size(packet),
          count: buffer.count + 1
      }
    else
      buffer
    end
  end

  def push(buffer, now, _, _), do: prune(buffer, now)

  def snapshot(buffer, now, started_at) do
    frames = buffer |> prune(now) |> Map.fetch!(:frames) |> :queue.to_list()
    speakers = frames |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    cond do
      frames == [] -> {:error, :empty}
      length(speakers) > @max_speakers -> {:error, :too_many_speakers}
      true -> {:ok, %{frames: frames, start: max(started_at, now - @window_ms), stop: now}}
    end
  end
end
