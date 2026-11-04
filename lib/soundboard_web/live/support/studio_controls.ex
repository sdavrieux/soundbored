defmodule SoundboardWeb.Live.Support.StudioControls do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component
  alias Soundboard.{AudioPlayer, Capture, MasterVolume, PubSubTopics}
  alias Soundboard.Capture.Moments

  def on_mount(:default, _params, session, socket) do
    user =
      case session do
        %{"user_id" => id} -> Soundboard.Repo.get(Soundboard.Accounts.User, id)
        _ -> nil
      end

    if connected?(socket), do: PubSubTopics.subscribe_desk()

    {:cont,
     socket
     |> assign(:current_user, user)
     |> assign(:studio_volume, MasterVolume.get())
     |> assign(:studio_capture, Capture.status())
     |> assign(:studio_naming, nil)
     |> attach_hook(:studio_events, :handle_event, &handle_event/3)
     |> attach_hook(:studio_messages, :handle_info, &handle_info/2)}
  end

  def handle_event(event, params, socket)
      when event in [
             "set_master_volume",
             "mute_master",
             "start_capture",
             "stop_capture",
             "save_moment",
             "name_moment",
             "skip_naming",
             "stop_sound"
           ] do
    if socket.assigns.current_user do
      {:halt, act(event, params, socket)}
    else
      {:halt, put_flash(socket, :error, "Sign in to use playback controls")}
    end
  end

  def handle_event(_, _, socket), do: {:cont, socket}

  defp act("set_master_volume", %{"volume" => volume}, socket) do
    case MasterVolume.set(volume) do
      {:ok, value} ->
        socket |> assign(:studio_volume, value) |> push_event("master-volume", %{volume: value})

      _ ->
        put_flash(socket, :error, "Choose a volume between 0 and 100%")
    end
  end

  defp act("mute_master", _, socket), do: act("set_master_volume", %{"volume" => 0}, socket)

  defp act("stop_sound", _, socket) do
    AudioPlayer.stop_sound()
    push_event(socket, "stop-all-sounds", %{})
  end

  defp act("skip_naming", _, socket), do: assign(socket, :studio_naming, nil)

  defp act("name_moment", %{"moment" => attrs}, socket) do
    case socket.assigns.studio_naming do
      %{name: name} ->
        tags = List.wrap(attrs["tags"]) ++ Moments.clean_tags(attrs["new_tags"] || "")

        case Capture.label(name, %{"title" => attrs["title"], "tags" => tags}) do
          :ok ->
            socket |> assign(:studio_naming, nil) |> put_flash(:info, "Moment named")

          _ ->
            put_flash(socket, :error, "Could not name this moment. Rename it in Saved moments.")
        end

      _ ->
        socket
    end
  end

  defp act("name_moment", _, socket), do: socket

  defp act(event, _, socket) do
    result =
      case event do
        "start_capture" -> Capture.start_capture()
        "stop_capture" -> Capture.stop_capture()
        "save_moment" -> Capture.save()
      end

    case result do
      {:ok, name} ->
        socket
        |> assign(:studio_capture, Capture.status())
        |> assign(:studio_naming, %{name: name, suggestions: Enum.take(Moments.all_tags(), 8)})

      :ok ->
        assign(socket, :studio_capture, Capture.status())

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  def handle_info({:master_volume, volume}, socket),
    do:
      {:halt,
       socket |> assign(:studio_volume, volume) |> push_event("master-volume", %{volume: volume})}

  def handle_info({:capture_status, status}, socket),
    do: {:halt, assign(socket, :studio_capture, status)}

  def handle_info({:capture_saved, result}, socket) do
    if socket.assigns[:current_path] == "/moments", do: send(self(), :reload_moments)

    socket =
      case result do
        {:ok, _} -> put_flash(socket, :info, "Moment saved")
        {:error, reason} ->
          socket |> assign(:studio_naming, nil) |> put_flash(:error, error_message(reason))
      end

    {:halt, socket}
  end

  def handle_info({:moments_updated, _}, socket) do
    if socket.assigns[:current_path] == "/moments", do: send(self(), :reload_moments)
    {:halt, socket}
  end

  def handle_info(_, socket), do: {:cont, socket}

  defp error_message(:voice_unavailable),
    do: "Join a voice channel and use !join before starting capture."

  defp error_message(:empty), do: "No voice audio in the last minute yet."
  defp error_message(:inactive), do: "Start capture first."
  defp error_message(:saving), do: "A moment is already being saved."

  defp error_message(:storage_full),
    do: "Recording folder is full. Delete moments before saving more."

  defp error_message(_),
    do: "Could not save this moment. Check recording storage and voice reception."
end
