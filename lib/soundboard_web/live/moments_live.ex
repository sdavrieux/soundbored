defmodule SoundboardWeb.MomentsLive do
  use SoundboardWeb, :live_view
  use SoundboardWeb.Live.Support.PresenceLive
  alias Soundboard.Capture.Moments
  alias Soundboard.Sounds

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> mount_presence(session)
     |> assign(:current_user, get_user_from_session(session))
     |> assign(:current_path, "/moments")
     |> assign(:moments, Moments.list())
     |> assign(:selected, nil)
     |> assign(:busy, false)}
  end

  @impl true
  def handle_event("select_moment", %{"name" => name}, socket) do
    case Moments.get(name) do
      {:ok, moment} -> {:noreply, select(socket, moment)}
      _ -> {:noreply, put_flash(socket, :error, "Moment no longer available")}
    end
  end

  def handle_event("edit_selection", %{"moment" => attrs}, socket),
    do: {:noreply, assign(socket, :selection, attrs)}

  def handle_event("save_changes", %{"moment" => attrs}, socket),
    do: operate(socket, :save, attrs)

  def handle_event("publish_moment", _, socket),
    do: operate(socket, :publish, socket.assigns.selection)

  def handle_event("delete_moment", _, socket), do: operate(socket, :delete, %{})

  defp operate(%{assigns: %{busy: true}} = socket, _, _), do: {:noreply, socket}
  defp operate(%{assigns: %{selected: nil}} = socket, _, _), do: {:noreply, socket}

  defp operate(%{assigns: %{current_user: nil}} = socket, _, _),
    do: {:noreply, put_flash(socket, :error, "Sign in to edit moments")}

  defp operate(socket, action, attrs) do
    moment = socket.assigns.selected
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:busy, true)
     |> start_async(:edit_moment, fn ->
       result =
         case action do
           :save -> Moments.save(moment.name, moment.revision, attrs)
           :publish -> Moments.publish(moment.name, moment.revision, attrs, user)
           :delete -> Moments.delete(moment.name, moment.revision)
         end

       {action, result}
     end)}
  end

  @impl true
  def handle_async(:edit_moment, {:ok, {action, result}}, socket) do
    socket = socket |> assign(:busy, false) |> assign(:moments, Moments.list())

    case {action, result} do
      {:save, {:ok, moment}} ->
        {:noreply, socket |> select(moment) |> put_flash(:info, "Changes saved")}

      {:publish, {:ok, _}} ->
        {:noreply, put_flash(socket, :info, "Published to Sounds")}

      {:delete, :ok} ->
        {:noreply, socket |> assign(:selected, nil) |> put_flash(:info, "Moment deleted")}

      {_, {:error, :stale}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This moment changed in another session. Select it again before editing."
         )}

      {_, {:error, :invalid_selection}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enter a name and choose at least 0.05 seconds within this recording."
         )}

      {_, {:error, error}} ->
        {:noreply, put_flash(socket, :error, Sounds.create_error_message(error))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update this moment")}
    end
  end

  def handle_async(:edit_moment, {:exit, _}, socket),
    do:
      {:noreply,
       socket |> assign(:busy, false) |> put_flash(:error, "Could not update this moment")}

  @impl true
  def handle_info(:reload_moments, socket),
    do: {:noreply, assign(socket, :moments, Moments.list())}

  defp select(socket, moment),
    do:
      socket
      |> assign(:selected, moment)
      |> assign(:selection, %{
        "title" => moment.title,
        "start" => "0",
        "stop" => to_string(moment.duration)
      })

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto px-4 py-8 text-gray-800 dark:text-gray-100">
      <h1 class="text-3xl font-bold mb-8">Saved moments</h1>
      <div :if={@moments == []} class="moment-editor">
        <p>No moments yet.</p>
        <.link navigate="/" class="inline-block mt-4 text-blue-600 dark:text-blue-300 underline">
          Go to Sounds to start capture
        </.link>
      </div>
      <div :if={@moments != []} class="grid lg:grid-cols-[280px_minmax(0,1fr)] gap-6">
        <div class="space-y-3" aria-label="Saved recordings">
          <button
            :for={moment <- @moments}
            class="moment-list-item"
            phx-click="select_moment"
            phx-value-name={moment.name}
            disabled={@busy}
            aria-current={to_string(@selected != nil and @selected.name == moment.name)}
          >
            <span class="block font-medium break-words">{moment.title}</span>
            <span class="block mt-1 text-sm text-gray-500 dark:text-gray-400">
              {Float.round(moment.duration, 2)} seconds
            </span>
          </button>
        </div>
        <div class="moment-editor">
          <p :if={@selected == nil}>Choose a moment to play or trim.</p>
          <div
            :if={@selected}
            id={"moment-editor-#{@selected.name}-#{@selected.revision}"}
            phx-hook="MomentEditor"
            data-duration={@selected.duration}
          >
            <h2 class="text-xl font-semibold mb-4 break-words">{@selected.title}</h2>
            <audio
              controls
              preload="metadata"
              class="w-full"
              src={"/moments/#{@selected.name}/audio?v=#{URI.encode(@selected.revision)}"}
              aria-label="Play saved moment"
            />
            <form
              id="moment-trim"
              phx-change="edit_selection"
              phx-submit="save_changes"
              class="mt-6 space-y-4"
            >
              <label class="block">
                Name<input
                  name="moment[title]"
                  value={@selection["title"]}
                  maxlength="100"
                  required
                  class="moment-field mt-2"
                  disabled={@busy}
                />
              </label>
              <div class="grid grid-cols-2 gap-4">
                <label>
                  Start (seconds)<input
                    data-bound="start"
                    name="moment[start]"
                    type="number"
                    step="0.01"
                    min="0"
                    max={@selected.duration}
                    value={@selection["start"]}
                    required
                    class="moment-field mt-2"
                    disabled={@busy}
                  />
                </label>
                <label>
                  End (seconds)<input
                    data-bound="stop"
                    name="moment[stop]"
                    type="number"
                    step="0.01"
                    min="0.05"
                    max={@selected.duration}
                    value={@selection["stop"]}
                    required
                    class="moment-field mt-2"
                    disabled={@busy}
                  />
                </label>
              </div>
              <label class="block text-sm">
                Trim start<input
                  data-range="start"
                  type="range"
                  min="0"
                  max={@selected.duration}
                  step="0.01"
                  value={@selection["start"]}
                  class="w-full h-11 accent-blue-600"
                  disabled={@busy}
                />
              </label>
              <label class="block text-sm">
                Trim end<input
                  data-range="stop"
                  type="range"
                  min="0.05"
                  max={@selected.duration}
                  step="0.01"
                  value={@selection["stop"]}
                  class="w-full h-11 accent-blue-600"
                  disabled={@busy}
                />
              </label>
              <div class="flex flex-wrap gap-3">
                <button
                  type="button"
                  data-preview
                  class="studio-button border border-gray-400"
                  disabled={@busy}
                >
                  Preview selection
                </button>
                <button type="submit" class="studio-button bg-blue-600 text-white" disabled={@busy}>
                  Save changes
                </button>
                <button
                  type="button"
                  phx-click="publish_moment"
                  class="studio-button bg-green-700 text-white"
                  disabled={@busy}
                >
                  Publish to Sounds
                </button>
              </div>
            </form>
            <div class="mt-8 pt-4 border-t border-gray-300 dark:border-gray-600 flex flex-wrap gap-4 items-center">
              <a
                href={"/recordings/#{@selected.name}"}
                download
                class="text-sm text-blue-600 dark:text-blue-300 underline"
              >
                Download WAV
              </a>
              <button
                type="button"
                phx-click="delete_moment"
                data-confirm="Delete this saved moment? This cannot be undone."
                disabled={@busy}
                class="studio-button text-red-600 dark:text-red-300"
              >
                Delete moment
              </button>
              <span :if={@busy} role="status" class="text-sm">Working…</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
