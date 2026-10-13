defmodule Soundboard.Capture.StorageTest do
  use ExUnit.Case, async: false
  alias Soundboard.Capture.Storage

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "soundboard-capture-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:soundboard, :recordings_dir)
    Application.put_env(:soundboard, :recordings_dir, dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:soundboard, :recordings_dir, previous),
        else: Application.delete_env(:soundboard, :recordings_dir)
    end)

    %{dir: dir}
  end

  test "only lists generated WAV names and refuses symlinks and traversal", %{dir: dir} do
    name = "moment-20260101T120000Z-0123456789abcdef.wav"
    File.write!(Path.join(dir, name), "RIFF")
    File.write!(Path.join(dir, "private.txt"), "private")
    assert Storage.list() == [name]
    assert {:ok, path} = Storage.download_path(name)
    assert path == Path.join(dir, name)
    assert {:error, :not_found} = Storage.download_path("../private.txt")
    File.rm!(path)
    File.ln_s!(Path.join(dir, "private.txt"), path)
    assert {:error, :not_found} = Storage.download_path(name)
  end

  test "FFmpeg exports mixed speakers with silence between turns and fixed duration", %{dir: dir} do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg, "Install FFmpeg to run recording integration tests"
    tone = Path.join(dir, "tone.ogg")

    assert {_, 0} =
             System.cmd(ffmpeg, [
               "-v",
               "error",
               "-f",
               "lavfi",
               "-i",
               "sine=frequency=440:duration=0.2",
               "-c:a",
               "libopus",
               "-frame_duration",
               "20",
               tone
             ])

    packets = tone |> File.read!() |> ogg_packets() |> Enum.drop(2) |> Enum.take(10)
    assert length(packets) == 10

    frames =
      for {packet, index} <- Enum.with_index(packets),
          {speaker, offset} <- [{"first", 200}, {"second", 1200}] do
        {offset + index * 20, speaker, packet}
      end

    assert {:ok, name} = Storage.save(%{frames: frames, start: 0, stop: 2000})
    assert Storage.list() == [name]
    assert {:ok, path} = Storage.download_path(name)
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {pcm, 0} =
             System.cmd(ffmpeg, [
               "-v",
               "error",
               "-i",
               path,
               "-f",
               "s16le",
               "-ac",
               "1",
               "-ar",
               "48000",
               "pipe:1"
             ])

    assert byte_size(pcm) == 2 * 48_000 * 2
    assert rms(pcm, 250) > 100
    assert rms(pcm, 1250) > 100
    assert rms(pcm, 800) < 5
    assert rms(pcm, 1800) < 5
    refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, ".export-"))
  end

  test "storage cap refuses additional moments", %{dir: dir} do
    for index <- 1..200 do
      suffix = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
      File.write!(Path.join(dir, "moment-20260101T120000Z-#{suffix}.wav"), "RIFF")
    end

    assert {:error, :storage_full} = Storage.save(%{frames: [], start: 0, stop: 100})
  end

  defp ogg_packets(<<>>), do: []

  defp ogg_packets(<<"OggS", _::binary-size(22), count, rest::binary>>) do
    <<segments::binary-size(count), rest::binary>> = rest
    lengths = for <<length <- segments>>, do: length
    size = Enum.sum(lengths)
    <<body::binary-size(size), tail::binary>> = rest

    {packets, <<>>, <<>>} =
      Enum.reduce(lengths, {[], <<>>, body}, fn length, {packets, part, body} ->
        <<chunk::binary-size(length), rest::binary>> = body
        part = part <> chunk
        if length == 255, do: {packets, part, rest}, else: {[part | packets], <<>>, rest}
      end)

    Enum.reverse(packets) ++ ogg_packets(tail)
  end

  defp rms(pcm, milliseconds) do
    chunk = binary_part(pcm, milliseconds * 48 * 2, 2400 * 2)
    samples = for <<sample::little-signed-16 <- chunk>>, do: sample * sample
    :math.sqrt(Enum.sum(samples) / length(samples))
  end
end
