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
     |> assign(:query, "")
     |> assign(:tag_filter, [])
     |> assign(:busy, false)}
  end

  @impl true
  def handle_event("search_moments", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :query, query)}

  def handle_event("toggle_moment_tag", %{"tag" => tag}, socket) do
    filter = socket.assigns.tag_filter

    filter = if tag in filter, do: List.delete(filter, tag), else: filter ++ [tag]
    {:noreply, assign(socket, :tag_filter, filter)}
  end

  def handle_event("clear_moment_tags", _, socket),
    do: {:noreply, assign(socket, :tag_filter, [])}

  def handle_event("close_moment", _, socket), do: {:noreply, assign(socket, :selected, nil)}

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

      {_, {:error, :untitled}} ->
        {:noreply, put_flash(socket, :error, "Name the moment before publishing it.")}

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
        "title" => if(moment.titled, do: moment.title, else: ""),
        "tags" => Enum.join(moment.tags, ", "),
        "start" => "0",
        "stop" => to_string(moment.duration)
      })

  @doc "Moments carrying every chosen tag whose name or tags contain the query."
  def visible(moments, query, tags) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(moments, fn moment ->
      Enum.all?(tags, &(&1 in moment.tags)) and
        (query == "" or String.contains?(String.downcase(moment.title), query) or
           Enum.any?(moment.tags, &String.contains?(&1, query)))
    end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible, visible(assigns.moments, assigns.query, assigns.tag_filter))
      |> assign(:all_tags, Moments.all_tags(assigns.moments))

    ~H"""
    <div class="page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Saved moments</h1>
          <p class="page-subtitle">
            {length(@moments)} saved · Private until you publish them to Sounds
          </p>
        </div>
      </header>
      <div :if={@moments == []} class="empty-state">
        <.icon name="hero-microphone" class="w-10 h-10 text-gray-400" />
        <h2 class="text-lg font-semibold">No moments yet</h2>
        <p>
          Tap <strong>Start capture</strong>
          in the bar below while the bot is in your voice channel, then <strong>Save last 60s</strong>
          when something good happens.
        </p>
      </div>
      <div :if={@moments != []} class={["moments-layout", @selected && "has-selection"]}>
        <div class="moments-list" aria-label="Saved recordings">
          <form phx-change="search_moments" phx-submit="search_moments" role="search">
            <label for="moment-search" class="sr-only">Search moments</label>
            <input
              id="moment-search"
              type="search"
              name="query"
              value={@query}
              placeholder="Search names and tags"
              phx-debounce="200"
              autocomplete="off"
              class="field"
            />
          </form>
          <div :if={@all_tags != []} class="chip-row" aria-label="Filter by tag">
            <button
              :for={tag <- @tag_filter ++ (@all_tags -- @tag_filter)}
              type="button"
              phx-click="toggle_moment_tag"
              phx-value-tag={tag}
              aria-pressed={to_string(tag in @tag_filter)}
              class={["chip", tag in @tag_filter && "is-active"]}
            >
              {tag}
            </button>
            <button
              :if={@tag_filter != []}
              type="button"
              phx-click="clear_moment_tags"
              class="chip chip-clear"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" /> Clear
            </button>
          </div>
          <p :if={@visible == []} class="text-sm text-gray-600 dark:text-gray-300">
            No moments match. Try fewer tags.
          </p>
          <button
            :for={moment <- @visible}
            class="moment-list-item"
            phx-click="select_moment"
            phx-value-name={moment.name}
            disabled={@busy}
            aria-current={to_string(@selected != nil and @selected.name == moment.name)}
          >
            <span class="block font-semibold break-words">
              <.moment_title id={"list-#{moment.name}"} moment={moment} />
            </span>
            <span class="block mt-1 text-sm text-gray-500 dark:text-gray-400">
              <%= if moment.titled do %>
                <.local_time id={"list-meta-#{moment.name}"} at={moment.recorded_at} /> ·
              <% end %>
              {format_duration(moment.duration)}
            </span>
            <span :if={moment.tags != []} class="mt-2 flex flex-wrap gap-1">
              <span :for={tag <- moment.tags} class="sound-pad-tag">{tag}</span>
            </span>
          </button>
        </div>
        <div class="moment-editor">
          <p :if={@selected == nil} class="text-gray-600 dark:text-gray-300">
            Choose a moment to play, trim, tag or publish.
          </p>
          <div
            :if={@selected}
            id={"moment-editor-#{@selected.name}-#{@selected.revision}"}
            phx-hook="MomentEditor"
            data-duration={@selected.duration}
          >
            <button type="button" phx-click="close_moment" class="moment-back">
              <.icon name="hero-chevron-left" class="w-5 h-5" /> All moments
            </button>
            <h2 class="text-xl font-semibold break-words">
              <.moment_title id="editor" moment={@selected} />
            </h2>
            <p class="mt-1 mb-4 text-sm text-gray-500 dark:text-gray-400">
              <.local_time id="editor-meta" at={@selected.recorded_at} /> · {format_duration(
                @selected.duration
              )}
            </p>
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
              class="mt-6 space-y-5"
            >
              <label class="block font-medium">
                Name<input
                  name="moment[title]"
                  value={@selection["title"]}
                  maxlength="100"
                  placeholder="Untitled moment"
                  autocomplete="off"
                  class="field mt-1"
                  disabled={@busy}
                />
              </label>
              <label class="block font-medium">
                Tags<input
                  name="moment[tags]"
                  value={@selection["tags"]}
                  placeholder="funny, fail, raid"
                  autocomplete="off"
                  class="field mt-1"
                  disabled={@busy}
                />
                <span class="field-hint">
                  Separate with commas. Published sounds get these tags too.
                </span>
              </label>
              <fieldset class="trim-box">
                <legend class="font-medium">Trim</legend>
                <div :for={
                  {bound, label, min} <- [{"start", "Start", "0"}, {"stop", "End", "0.05"}]
                } class="trim-row">
                  <label for={"trim-#{bound}"} class="trim-label">{label}</label>
                  <input
                    data-range={bound}
                    type="range"
                    min={min}
                    max={@selected.duration}
                    step="0.01"
                    value={@selection[bound]}
                    aria-label={"#{label} position"}
                    class="trim-slider"
                    disabled={@busy}
                  />
                  <input
                    id={"trim-#{bound}"}
                    data-bound={bound}
                    name={"moment[#{bound}]"}
                    type="number"
                    inputmode="decimal"
                    step="0.01"
                    min={min}
                    max={@selected.duration}
                    value={@selection[bound]}
                    required
                    class="field trim-seconds"
                    disabled={@busy}
                  />
                  <span class="text-sm text-gray-500 dark:text-gray-400">s</span>
                </div>
                <button
                  type="button"
                  data-preview
                  class="studio-button btn-secondary w-full sm:w-auto"
                  disabled={@busy}
                >
                  <.icon name="hero-play" class="w-5 h-5" /> Preview selection
                </button>
              </fieldset>
              <div class="flex flex-col sm:flex-row gap-3">
                <button
                  type="button"
                  phx-click="publish_moment"
                  class="studio-button btn-primary"
                  disabled={@busy}
                >
                  <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> Publish to Sounds
                </button>
                <button type="submit" class="studio-button btn-secondary" disabled={@busy}>
                  Save name, tags and trim
                </button>
              </div>
              <p class="field-hint">
                Saving a trim replaces this private recording. Publishing makes a copy in Sounds
                and leaves the recording as it is.
              </p>
            </form>
            <div class="mt-8 pt-4 border-t border-gray-200 dark:border-gray-700 flex flex-wrap gap-3 items-center">
              <a href={"/recordings/#{@selected.name}"} download class="studio-button btn-secondary">
                <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Download WAV
              </a>
              <button
                type="button"
                phx-click="delete_moment"
                data-confirm="Delete this saved moment? This cannot be undone."
                disabled={@busy}
                class="studio-button btn-danger-soft"
              >
                <.icon name="hero-trash" class="w-5 h-5" /> Delete moment
              </button>
              <span :if={@busy} role="status" class="text-sm">Working…</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :moment, :map, required: true

  defp moment_title(%{moment: %{titled: true}} = assigns), do: ~H"{@moment.title}"
  defp moment_title(%{moment: %{recorded_at: nil}} = assigns), do: ~H"{@moment.title}"

  defp moment_title(assigns) do
    ~H"""
    Moment, <.local_time id={"#{@id}-title"} at={@moment.recorded_at} />
    """
  end

  attr :id, :string, required: true
  attr :at, :string, default: nil

  # Recordings are named in UTC; the LocalTime hook rewrites this in the viewer's time zone.
  defp local_time(assigns) do
    ~H"""
    <time
      :if={@at}
      id={"time-#{@id}"}
      datetime={@at}
      phx-hook="LocalTime"
    >{String.replace(String.slice(@at, 0, 16), "T", " ") <> " UTC"}</time>
    """
  end

  defp format_duration(seconds) when seconds < 60, do: "#{Float.round(seconds * 1.0, 1)} s"

  defp format_duration(seconds) do
    total = round(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
