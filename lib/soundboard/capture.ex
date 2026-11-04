defmodule Soundboard.Capture do
  @moduledoc """
  Opt-in rolling channel capture. Unsaved audio exists only in a bounded RAM buffer.
  Disconnecting, switching channels, or stopping capture discards the buffer.
  Exports run under a supervisor so recording continues while a moment is saved.
  """
  use GenServer
  import Ecto.Query, only: [from: 2]
  alias Soundboard.Accounts.User
  alias Soundboard.Capture.{Buffer, Moments, Storage}
  alias Soundboard.Discord.{Handler, Voice}
  alias Soundboard.PubSubTopics

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)

  def start_capture do
    target = Handler.get_current_voice_channel()
    GenServer.call(__MODULE__, {:start, target})
  end

  def stop_capture, do: GenServer.call(__MODULE__, :stop)
  @doc "Freezes the last minute and starts exporting it. Returns the new moment's name."
  def save, do: GenServer.call(__MODULE__, :save)

  @doc """
  Names and tags a moment. If it is still exporting, the label is applied as soon as
  the file exists, so the operator can type while FFmpeg works.
  """
  def label(name, attrs) do
    case GenServer.call(__MODULE__, {:label, name, attrs}) do
      :pending -> :ok
      :saved -> with {:ok, _} <- Moments.label(name, attrs), do: :ok
    end
  end

  def active?(guild_id) do
    %{target: target} = status()
    match?({^guild_id, _}, target)
  end

  def ingest(payload) do
    GenServer.call(__MODULE__, {:audio, payload})
  catch
    :exit, _ -> :error
  end

  def channel_changed(guild_id, channel_id),
    do: GenServer.cast(__MODULE__, {:channel_changed, guild_id, channel_id})

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, 1000)
    {:ok,
     %{target: nil, started_at: nil, buffer: %Buffer{}, export: nil, export_name: nil, label: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:start, target}, _from, %{target: nil} = state) do
    with {guild_id, channel_id} <- target,
         true <- Voice.ready?(guild_id),
         :ok <- Voice.start_listening(guild_id) do
      state = %{state | target: {guild_id, channel_id}, started_at: now(), buffer: %Buffer{}}
      broadcast(state)
      {:reply, :ok, state}
    else
      _ -> {:reply, {:error, :voice_unavailable}, state}
    end
  catch
    :exit, _ -> {:reply, {:error, :voice_unavailable}, state}
  end

  def handle_call({:start, _target}, _from, state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    state = clear_capture(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:save, _from, %{export: export} = state) when not is_nil(export),
    do: {:reply, {:error, :saving}, state}

  def handle_call(:save, _from, %{target: nil} = state),
    do: {:reply, {:error, :inactive}, state}

  def handle_call(:save, _from, state) do
    case Buffer.snapshot(state.buffer, now(), state.started_at) do
      {:ok, snapshot} ->
        name = Storage.new_name()

        task =
          Task.Supervisor.async_nolink(Soundboard.Capture.Tasks, fn ->
            with {:ok, ^name} <- Storage.save(snapshot, name) do
              Moments.label(name, %{"tags" => speaker_tags(snapshot.frames)})
              {:ok, name}
            end
          end)

        state = %{state | export: task.ref, export_name: name, label: nil}
        broadcast(state)
        {:reply, {:ok, name}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:label, name, attrs}, _from, %{export_name: name} = state),
    do: {:reply, :pending, %{state | label: attrs}}

  def handle_call({:label, _name, _attrs}, _from, state), do: {:reply, :saved, state}

  def handle_call(
        {:audio, %{guild_id: guild, user_id: speaker, opus: packet}},
        _from,
        %{target: {guild, _}} = state
      ) do
    buffer = Buffer.push(state.buffer, now(), speaker, packet)
    {:reply, :ok, %{state | buffer: buffer}}
  end

  def handle_call({:audio, _}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:channel_changed, guild, channel}, %{target: {guild, old}} = state)
      when channel != old do
    state = clear_capture(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:channel_changed, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1000)
    next = maintain_capture(state)
    if state.target, do: broadcast(next)
    {:noreply, next}
  end

  def handle_info({ref, result}, %{export: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    with {{:ok, name}, %{} = label} <- {result, state.label},
         do: Moments.label(name, label)

    state = %{state | export: nil, export_name: nil, label: nil}
    PubSubTopics.broadcast_desk({:capture_saved, result})
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{export: ref} = state) do
    state = %{state | export: nil, export_name: nil, label: nil}
    PubSubTopics.broadcast_desk({:capture_saved, {:error, :export_failed}})
    broadcast(state)
    {:noreply, state}
  end

  defp maintain_capture(%{target: nil} = state), do: state

  defp maintain_capture(%{target: {guild, channel}} = state) do
    if Voice.ready?(guild) and Voice.channel_id(guild) == channel do
      %{state | buffer: Buffer.prune(state.buffer, now())}
    else
      clear_capture(state)
    end
  catch
    :exit, _ -> clear_capture(state)
  end

  defp clear_capture(%{target: {guild, _}} = state) do
    Voice.stop_listening(guild)
    %{state | target: nil, started_at: nil, buffer: %Buffer{}}
  catch
    :exit, _ -> %{state | target: nil, started_at: nil, buffer: %Buffer{}}
  end

  defp clear_capture(state), do: state

  defp public_status(state) do
    %{
      target: state.target,
      saving: state.export != nil,
      seconds: if(state.started_at, do: min(60, div(now() - state.started_at, 1000)), else: 0),
      has_audio: Buffer.prune(state.buffer, now()).count > 0
    }
  end

  # Who was talking is the easiest way to find a clip later. Only operators who
  # signed in have a known name; other speakers are left untagged.
  defp speaker_tags(frames) do
    ids = frames |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    Soundboard.Repo.all(from u in User, where: u.discord_id in ^ids, select: u.username)
  rescue
    _ -> []
  end

  defp broadcast(state), do: PubSubTopics.broadcast_desk({:capture_status, public_status(state)})
  defp now, do: System.monotonic_time(:millisecond)
end
