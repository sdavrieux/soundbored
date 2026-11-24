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
     |> assign(:analysis, nil)
     |> assign(:highlights, [])
     |> assign(:query, "")
     |> assign(:tag_filter, [])
     |> assign(:tag_query, "")
     |> assign(:sound_tags, Sounds.Tags.all_names())
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

  def handle_event("edit_selection", %{"moment" => attrs}, socket) do
    attrs = Map.put(attrs, "speakers", socket.assigns.selection["speakers"])
    {:noreply, socket |> assign(:selection, attrs) |> refresh_highlights()}
  end

  def handle_event("set_speakers", %{"moment" => attrs}, socket) do
    speakers = attrs |> Map.get("speakers", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    selection = Map.put(socket.assigns.selection, "speakers", speakers)

    {:noreply, socket |> assign(:selection, selection) |> refresh_highlights()}
  end

  def handle_event("moment_tag_query", %{"tag" => query}, socket),
    do: {:noreply, assign(socket, :tag_query, query)}

  def handle_event("add_moment_tag", %{"tag" => tag}, socket) do
    tags = Moments.clean_tags(chosen_tags(socket.assigns.selection) ++ [tag])

    {:noreply,
     socket
     |> assign(:selection, Map.put(socket.assigns.selection, "tags", Enum.join(tags, ", ")))
     |> assign(:tag_query, "")}
  end

  def handle_event("remove_moment_tag", %{"tag" => tag}, socket) do
    tags = List.delete(chosen_tags(socket.assigns.selection), tag)

    {:noreply,
     assign(socket, :selection, Map.put(socket.assigns.selection, "tags", Enum.join(tags, ", ")))}
  end

  def handle_event("auto_trim", _, %{assigns: %{analysis: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("auto_trim", _, socket) do
    case Moments.speech_bounds(socket.assigns.analysis, chosen(socket.assigns)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Nobody speaks in this selection.")}

      {start, stop} ->
        {:noreply, socket |> set_range(start, stop) |> push_event("moment-preview", %{})}
    end
  end

  def handle_event("jump_highlight", %{"index" => index}, socket) do
    with {index, ""} <- Integer.parse(index),
         %{start: start, stop: stop} <- Enum.at(socket.assigns.highlights, index) do
      {:noreply, socket |> set_range(start, stop) |> push_event("moment-preview", %{})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_changes", %{"moment" => attrs}, socket),
    do: operate(socket, :save, Map.put(attrs, "speakers", socket.assigns.selection["speakers"]))

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

      {_, {:error, error}} ->
        {:noreply, put_flash(socket, :error, error_message(error))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update this moment")}
    end
  end

  def handle_async(:edit_moment, {:exit, _}, socket),
    do:
      {:noreply,
       socket |> assign(:busy, false) |> put_flash(:error, "Could not update this moment")}

  def handle_async(:analyze, {:ok, {:ok, analysis}}, socket) do
    case socket.assigns.selected do
      %{name: name, revision: revision}
      when name == analysis.name and revision == analysis.revision ->
        {:noreply, socket |> assign(:analysis, analysis) |> refresh_highlights()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async(:analyze, _, socket), do: {:noreply, socket}

  defp error_message(:stale),
    do: "This moment changed in another session. Select it again before editing."

  defp error_message(:no_speakers), do: "Keep at least one speaker in the mix."
  defp error_message(:untitled), do: "Name the moment before publishing it."

  defp error_message(:invalid_selection),
    do: "Enter a name and choose at least 0.05 seconds within this recording."

  defp error_message(error), do: Sounds.create_error_message(error)

  @impl true
  def handle_info(:reload_moments, socket),
    do: {:noreply, assign(socket, :moments, Moments.list())}

  defp select(socket, moment) do
    socket
    |> assign(:selected, moment)
    |> assign(:analysis, nil)
    |> assign(:highlights, [])
    |> assign(:tag_query, "")
    |> assign(:selection, %{
      "title" => if(moment.titled, do: moment.title, else: ""),
      "tags" => Enum.join(moment.tags, ", "),
      "start" => "0",
      "stop" => to_string(moment.duration),
      "speakers" => Moments.active_speakers(moment)
    })
    |> start_async(:analyze, fn -> Moments.analyze(moment.name) end)
  end

  defp set_range(socket, start, stop) do
    selection =
      socket.assigns.selection
      |> Map.put("start", to_string(start))
      |> Map.put("stop", to_string(stop))

    assign(socket, :selection, selection)
  end

  defp chosen_tags(selection), do: Moments.clean_tags(selection["tags"])

  # Existing tags not yet on this moment that contain the query, moment tags first.
  defp tag_matches(assigns) do
    query = assigns.tag_query |> String.trim() |> String.downcase()
    taken = chosen_tags(assigns.selection)

    (assigns.all_tags ++ Enum.map(assigns.sound_tags, &String.downcase/1))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in taken or not String.contains?(&1, query)))
    |> Enum.take(12)
  end

  defp new_tag(assigns) do
    case Moments.clean_tags([assigns.tag_query]) do
      [tag] ->
        known = assigns.all_tags ++ Enum.map(assigns.sound_tags, &String.downcase/1)
        if tag in known or tag in chosen_tags(assigns.selection), do: nil, else: tag

      _ ->
        nil
    end
  end

  defp chosen(%{selected: %{speakers: []}}), do: []
  defp chosen(%{selection: selection}), do: selection["speakers"] || []

  defp refresh_highlights(%{assigns: %{analysis: nil}} = socket), do: socket

  defp refresh_highlights(socket),
    do:
      assign(
        socket,
        :highlights,
        Moments.highlights(socket.assigns.analysis, chosen(socket.assigns))
      )

  # Listening to a different speaker mix than the saved one needs a server-side remix.
  defp audio_src(moment, selection) do
    base = "/moments/#{moment.name}/audio?v=#{URI.encode(moment.revision)}"
    speakers = selection["speakers"] || []

    if moment.speakers == [] or speakers == [] or speakers == Moments.active_speakers(moment),
      do: base,
      else: base <> "&speakers=" <> Enum.join(speakers, ",")
  end

  defp highlight_label(highlight) do
    [
      highlight.loud && "Loud",
      highlight.voices > 1 && "#{highlight.voices} talking"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

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

    assigns =
      if assigns.selected,
        do:
          assigns
          |> assign(:tag_matches, tag_matches(assigns))
          |> assign(:new_tag, new_tag(assigns)),
        else: assigns

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
            data-src={audio_src(@selected, @selection)}
            data-duration={@selected.duration}
            data-start={@selection["start"]}
            data-stop={@selection["stop"]}
            data-highlights={Jason.encode!(Enum.map(@highlights, &[&1.start, &1.stop]))}
          >
            <button type="button" phx-click="close_moment" class="moment-back">
              <.icon name="hero-chevron-left" class="w-5 h-5" /> All moments
            </button>
            <h2 class="text-xl font-semibold break-words">
              <.moment_title id="editor" moment={@selected} />
            </h2>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              <.local_time id="editor-meta" at={@selected.recorded_at} />
              · {format_duration(@selected.duration)}
            </p>

            <form
              :if={@selected.speakers != []}
              id="moment-speakers"
              phx-change="set_speakers"
              class="editor-section"
              aria-labelledby="speakers-heading"
            >
              <h3 id="speakers-heading" class="editor-heading">Speakers</h3>
              <input type="hidden" name="moment[speakers][]" value="" />
              <div class="chip-wrap">
                <label
                  :for={speaker <- @selected.speakers}
                  class={["chip", speaker.id in (@selection["speakers"] || []) && "is-active"]}
                >
                  <input
                    type="checkbox"
                    name="moment[speakers][]"
                    value={speaker.id}
                    checked={speaker.id in (@selection["speakers"] || [])}
                    class="sr-only"
                    disabled={@busy}
                  />
                  {speaker.name}
                </label>
              </div>
              <p :if={(@selection["speakers"] || []) == []} class="field-hint text-red-600">
                Keep at least one speaker.
              </p>
              <p :if={(@selection["speakers"] || []) != []} class="field-hint">
                Tap a name to leave them out. The waveform and player switch to the new mix.
              </p>
            </form>

            <section class="editor-section" aria-labelledby="cut-heading">
              <h3 id="cut-heading" class="editor-heading">Cut</h3>
              <div id={"cutter-#{@selected.name}-#{@selected.revision}"} phx-update="ignore">
                <.cutter />
              </div>
              <div class="cut-tools">
                <button
                  type="button"
                  phx-click="auto_trim"
                  class="chip"
                  disabled={@busy or @analysis == nil}
                  title="Cut the silence before the first and after the last word"
                >
                  <.icon name="hero-scissors" class="w-4 h-4" /> Auto-trim
                </button>
                <span :if={@analysis == nil} class="field-hint">Finding highlights…</span>
                <button
                  :for={{highlight, index} <- Enum.with_index(@highlights)}
                  type="button"
                  phx-click="jump_highlight"
                  phx-value-index={index}
                  class="chip chip-highlight"
                  disabled={@busy}
                  title="Cut around this highlight and play it"
                >
                  🔥 {format_clock(highlight.at)}
                  <span class="chip-count">{highlight_label(highlight)}</span>
                </button>
              </div>
            </section>

            <form id="moment-trim" phx-change="edit_selection" phx-submit="save_changes">
              <input type="hidden" id="trim-start" name="moment[start]" value={@selection["start"]} />
              <input type="hidden" id="trim-stop" name="moment[stop]" value={@selection["stop"]} />

              <section class="editor-section space-y-4" aria-labelledby="label-heading">
                <h3 id="label-heading" class="editor-heading">Name and tags</h3>
                <label class="block font-medium">
                  Name<input
                    id="moment-title"
                    name="moment[title]"
                    value={@selection["title"]}
                    maxlength="100"
                    placeholder="e.g. Sam's clutch save"
                    autocomplete="off"
                    phx-debounce="300"
                    class="field mt-1"
                    disabled={@busy}
                  />
                </label>
                <input type="hidden" name="moment[tags]" value={@selection["tags"]} />
                <div id="moment-tags">
                  <label for="moment-tag-query" class="block font-medium">Tags</label>
                  <div :if={chosen_tags(@selection) != []} class="chip-wrap mt-1">
                    <button
                      :for={tag <- chosen_tags(@selection)}
                      type="button"
                      phx-click="remove_moment_tag"
                      phx-value-tag={tag}
                      class="chip is-active"
                      aria-label={"Remove tag #{tag}"}
                      disabled={@busy}
                    >
                      {tag} <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <input
                    id="moment-tag-query"
                    form="moment-new-tag"
                    name="tag"
                    value={@tag_query}
                    placeholder="Find or create a tag"
                    autocomplete="off"
                    phx-debounce="150"
                    class="field mt-2"
                    disabled={@busy}
                  />
                  <div class="chip-wrap mt-2">
                    <button
                      :if={@new_tag}
                      type="button"
                      phx-click="add_moment_tag"
                      phx-value-tag={@new_tag}
                      class="chip chip-clear"
                      disabled={@busy}
                    >
                      <.icon name="hero-plus" class="w-4 h-4" /> Create “{@new_tag}”
                    </button>
                    <button
                      :for={tag <- @tag_matches}
                      type="button"
                      phx-click="add_moment_tag"
                      phx-value-tag={tag}
                      class="chip"
                      disabled={@busy}
                    >
                      {tag}
                    </button>
                  </div>
                  <span class="field-hint">
                    Tap a tag to add it, or type a new one and press Enter. Published sounds get these tags too.
                  </span>
                </div>
              </section>

              <section class="editor-section" aria-labelledby="finish-heading">
                <h3 id="finish-heading" class="editor-heading">Finish</h3>
                <div class="finish-grid">
                  <div class="finish-option">
                    <button
                      id="publish-moment"
                      type="button"
                      phx-click="publish_moment"
                      class="studio-button btn-primary w-full"
                      disabled={@busy}
                    >
                      <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> Publish cut to Sounds
                    </button>
                    <p
                      :if={untitled?(@selection)}
                      class="field-hint text-amber-700 dark:text-amber-400"
                    >
                      Add a name above to publish.
                    </p>
                    <p :if={!untitled?(@selection)} class="field-hint">
                      Adds the cut as a new sound on the board. This recording stays as it is.
                    </p>
                  </div>
                  <div class="finish-option">
                    <button type="submit" class="studio-button btn-secondary w-full" disabled={@busy}>
                      <.icon name="hero-check" class="w-5 h-5" /> Save cut to this recording
                    </button>
                    <p class="field-hint">
                      Keeps only the cut and chosen speakers in this private recording.
                    </p>
                  </div>
                </div>
                <p :if={@busy} role="status" class="field-hint">Working…</p>
              </section>
            </form>
            <form id="moment-new-tag" phx-change="moment_tag_query" phx-submit="add_moment_tag">
            </form>

            <div class="editor-section flex flex-wrap gap-3 items-center">
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
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Driven entirely by the MomentEditor hook: LiveView never patches inside it, so
  # dragging and playback are never interrupted by server updates.
  defp cutter(assigns) do
    ~H"""
    <div class="cutter" data-cutter>
      <div class="wave" data-wave>
        <canvas aria-hidden="true"></canvas>
        <div class="wave-shade" data-shade="start"></div>
        <div class="wave-shade" data-shade="stop"></div>
        <div class="wave-playhead" data-playhead hidden></div>
        <button
          :for={{bound, label} <- [{"start", "Start of the cut"}, {"stop", "End of the cut"}]}
          type="button"
          class="wave-handle"
          data-handle={bound}
          role="slider"
          aria-label={label}
          aria-valuemin="0"
        >
        </button>
        <p class="wave-status" data-status>Loading audio…</p>
      </div>
      <div class="cut-times">
        <div
          :for={{bound, label} <- [{"start", "Start"}, {"stop", "End"}]}
          class={"cut-bound cut-#{bound}"}
        >
          <span class="cut-label">{label}</span>
          <div class="cut-nudge">
            <button type="button" data-nudge={"#{bound}:-0.1"} aria-label={"#{label} 0.1 s earlier"}>
              −
            </button>
            <output class="cut-time" data-time={bound}>0:00.00</output>
            <button type="button" data-nudge={"#{bound}:0.1"} aria-label={"#{label} 0.1 s later"}>
              +
            </button>
          </div>
          <button type="button" class="cut-mark" data-mark={bound}>Set to playhead</button>
        </div>
        <div class="cut-length">
          <span class="cut-label">Length</span>
          <output class="cut-time" data-time="length">0.00 s</output>
        </div>
      </div>
      <div class="cut-transport">
        <button type="button" class="studio-button btn-primary" data-play="selection">
          <span data-idle><.icon name="hero-play-solid" class="w-5 h-5" /> Play cut</span>
          <span data-busy><.icon name="hero-stop-solid" class="w-5 h-5" /> Stop</span>
        </button>
        <button type="button" class="studio-button btn-secondary" data-play="all">
          <span data-idle><.icon name="hero-play" class="w-5 h-5" /> Play from playhead</span>
          <span data-busy><.icon name="hero-stop-solid" class="w-5 h-5" /> Stop</span>
        </button>
      </div>
      <p class="field-hint">
        Drag the blue handles, or tap the waveform to listen from there and use <strong>Set to playhead</strong>. − and + move an end by 0.1 s and replay it.
      </p>
    </div>
    """
  end

  defp untitled?(selection), do: String.trim(selection["title"] || "") == ""

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
    >
      {String.replace(String.slice(@at, 0, 16), "T", " ") <> " UTC"}
    </time>
    """
  end

  defp format_clock(seconds) do
    total = trunc(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_duration(seconds) when seconds < 60, do: "#{Float.round(seconds * 1.0, 1)} s"

  defp format_duration(seconds) do
    total = round(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
