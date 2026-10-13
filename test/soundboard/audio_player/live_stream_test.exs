defmodule Soundboard.AudioPlayer.LiveStreamTest do
  use Soundboard.DataCase, async: false
  alias Soundboard.AudioPlayer.LiveStream
  alias Soundboard.{Capture.Ogg, MasterVolume}

  test "a single playing stream responds to master changes without restarting its encoder" do
    dir =
      Path.join(System.tmp_dir!(), "soundboard-live-test-#{System.unique_integer([:positive])}")

    File.mkdir!(dir)
    previous = MasterVolume.current()

    on_exit(fn ->
      :persistent_term.put({MasterVolume, :volume}, previous)
      File.rm_rf!(dir)
    end)

    source = Path.join(dir, "tone.wav")
    ffmpeg = System.find_executable("ffmpeg")

    assert {_, 0} =
             System.cmd(ffmpeg, [
               "-v",
               "error",
               "-f",
               "lavfi",
               "-i",
               "sine=frequency=440:duration=2",
               "-ac",
               "2",
               "-ar",
               "48000",
               source
             ])

    assert {:ok, 100} = MasterVolume.set(100)

    packets =
      source
      |> LiveStream.frames(1.0)
      |> Stream.with_index()
      |> Enum.map(fn {frame, index} ->
        if index == 30, do: MasterVolume.set(20)
        {index * 20, "speaker", frame}
      end)

    assert length(packets) in 100..102
    ogg = Path.join(dir, "encoded.ogg")
    File.write!(ogg, Ogg.stream(packets, 0, 1))

    assert {pcm, 0} =
             System.cmd(ffmpeg, ["-v", "error", "-i", ogg, "-f", "s16le", "-ac", "1", "pipe:1"])

    loud = rms(pcm, 200)
    quiet = rms(pcm, 1400)
    assert loud > 1000
    assert quiet / loud > 0.16
    assert quiet / loud < 0.24
  end

  test "owner death tears down the encoder and its private FIFO" do
    source =
      Path.join(
        System.tmp_dir!(),
        "soundboard-stop-test-#{System.unique_integer([:positive])}.wav"
      )

    on_exit(fn -> File.rm(source) end)

    assert {_, 0} =
             System.cmd(System.find_executable("ffmpeg"), [
               "-v",
               "error",
               "-f",
               "lavfi",
               "-i",
               "sine=duration=10",
               source
             ])

    parent = self()

    owner =
      spawn(fn ->
        {:ok, worker} = GenServer.start(LiveStream, {self(), source, 1.0})
        send(parent, {:worker, worker, :sys.get_state(worker).work})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:worker, worker, work}, 3000
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3000
    refute File.exists?(work)
  end

  defp rms(pcm, ms) do
    samples =
      for <<value::little-signed-16 <- binary_part(pcm, ms * 48 * 2, 4800 * 2)>>,
        do: value * value

    :math.sqrt(Enum.sum(samples) / length(samples))
  end
end
