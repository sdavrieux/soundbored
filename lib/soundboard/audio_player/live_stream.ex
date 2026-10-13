defmodule Soundboard.AudioPlayer.LiveStream do
  @moduledoc "Encodes live master attenuation before handing Opus frames to EDA."
  use GenServer
  alias EDA.Voice.Ogg
  alias Soundboard.{MasterVolume, PubSubTopics}
  @chunk 3840

  def frames(input, clip_gain) do
    Stream.resource(
      fn ->
        {:ok, pid} = GenServer.start(__MODULE__, {self(), input, clip_gain})
        pid
      end,
      fn pid ->
        case next_frame(pid) do
          :done -> {:halt, pid}
          frame -> {[frame], pid}
        end
      end,
      fn pid -> if Process.alive?(pid), do: GenServer.stop(pid) end
    )
  end

  defp next_frame(pid) do
    GenServer.call(pid, :next, 15_000)
  catch
    :exit, _ ->
      PubSubTopics.broadcast_error("Could not decode this sound. Try another clip.")
      :done
  end

  @impl true
  def init({owner, input, gain}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)
    ffmpeg = System.find_executable("ffmpeg") || raise "FFmpeg is required"

    work =
      Path.join(
        System.tmp_dir!(),
        "soundboard-play-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(work)
    File.chmod!(work, 0o700)
    fifo = Path.join(work, "pcm")
    {_, 0} = System.cmd("mkfifo", ["-m", "600", fifo])

    encoder =
      port(System.find_executable("sh"), [
        "-c",
        "fifo=$1; shift; exec \"$@\" < \"$fifo\"",
        "soundboard-encoder",
        fifo,
        ffmpeg,
        "-v",
        "quiet",
        "-f",
        "s16le",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-probesize",
        "32",
        "-analyzeduration",
        "0",
        "-blocksize",
        "3840",
        "-i",
        "pipe:0",
        "-c:a",
        "libopus",
        "-frame_duration",
        "20",
        "-f",
        "ogg",
        "-page_duration",
        "20000",
        "-flush_packets",
        "1",
        "pipe:1"
      ])

    {:ok, writer} = File.open(fifo, [:write, :binary])

    decoder =
      port(ffmpeg, [
        "-nostdin",
        "-v",
        "quiet",
        "-re",
        "-i",
        input,
        "-vn",
        "-f",
        "s16le",
        "-ar",
        "48000",
        "-ac",
        "2",
        "pipe:1"
      ])

    {:ok,
     %{
       ref: ref,
       decoder: decoder,
       encoder: encoder,
       writer: writer,
       work: work,
       gain: gain,
       pending: 0,
       pcm: <<>>,
       ogg: <<>>,
       skip: 2,
       frames: [],
       eof: false,
       finished: false
     }}
  end

  @impl true
  def handle_call(:next, _, state) do
    {frame, state} = next(state)
    {:reply, frame, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = state), do: {:stop, :normal, state}
  def handle_info(message, state), do: {:noreply, absorb(message, state)}

  defp next(%{frames: [frame | rest]} = state), do: {frame, %{state | frames: rest}}
  defp next(%{finished: true} = state), do: {:done, state}

  defp next(%{pcm: pcm, pending: pending} = state)
       when byte_size(pcm) >= @chunk and pending < 16 do
    <<chunk::binary-size(@chunk), rest::binary>> = pcm
    :ok = IO.binwrite(state.writer, scale(chunk, state.gain * MasterVolume.current() / 100))
    state = %{state | pcm: rest, pending: pending + 1}

    receive do
      message -> next(absorb(message, state))
    after
      5 -> next(state)
    end
  end

  defp next(%{eof: true, writer: writer, pcm: pcm} = state)
       when not is_nil(writer) and byte_size(pcm) < @chunk do
    if state.pcm != <<>>,
      do: IO.binwrite(writer, scale(state.pcm, state.gain * MasterVolume.current() / 100))

    File.close(writer)
    next(%{state | writer: nil, pcm: <<>>})
  end

  defp next(state) do
    receive do
      message -> next(absorb(message, state))
    after
      10_000 -> raise "Audio encoder timed out"
    end
  end

  defp absorb({port, {:data, data}}, %{decoder: port} = state) do
    pcm = state.pcm <> data
    if byte_size(pcm) > 1_048_576, do: raise("Audio decoder exceeded its buffer limit")
    %{state | pcm: pcm}
  end

  defp absorb({port, {:data, data}}, %{encoder: port} = state) do
    {frames, rest, skip} = Ogg.extract_frames(state.ogg <> data, state.skip)

    %{
      state
      | ogg: rest,
        skip: skip,
        frames: state.frames ++ frames,
        pending: max(0, state.pending - length(frames))
    }
  end

  defp absorb({port, {:exit_status, 0}}, %{decoder: port} = state), do: %{state | eof: true}
  defp absorb({port, {:exit_status, 0}}, %{encoder: port} = state), do: %{state | finished: true}
  defp absorb({_, {:exit_status, _}}, _), do: raise("Audio conversion failed")
  defp absorb({:DOWN, ref, :process, _, _}, %{ref: ref}), do: exit(:normal)
  defp absorb(_, state), do: state

  def scale(pcm, gain) do
    for <<sample::little-signed-16 <- pcm>>, into: <<>> do
      value = (sample * gain) |> round() |> max(-32_768) |> min(32_767)
      <<value::little-signed-16>>
    end
  end

  @impl true
  def terminate(_, state) do
    if state.writer, do: File.close(state.writer)
    for port <- [state.decoder, state.encoder], Port.info(port) != nil, do: Port.close(port)
    File.rm_rf(state.work)
  end

  defp port(executable, args),
    do: Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])
end
