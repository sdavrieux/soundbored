defmodule SoundboardWeb.StatsLive do
  use SoundboardWeb, :live_view
  use SoundboardWeb.Live.Support.PresenceLive
  alias SoundboardWeb.PresenceHandler
  import Phoenix.Component
  import SoundboardWeb.SoundHelpers
  alias Soundboard.{Accounts, Favorites, PubSubTopics, Sounds, Stats}
  alias SoundboardWeb.Live.Support.{FlashHelpers, SoundPlayback}
  import FlashHelpers, only: [clear_flash_after_timeout: 1]
  require Logger

  @recent_limit 5

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      :timer.send_interval(60 * 60 * 1000, self(), :check_week_rollover)
      PubSubTopics.subscribe_playback()
      PubSubTopics.subscribe_stats()
    end

    current_week = get_week_range()

    {:ok,
     socket
     |> mount_presence(session)
     |> assign(:current_path, "/stats")
     |> assign(:current_user, get_user_from_session(session))
     |> assign(:force_update, 0)
     |> assign(:selected_week, current_week)
     |> assign(:current_week, current_week)
     |> stream_configure(:recent_plays, dom_id: &recent_play_dom_id/1)
     |> stream(:recent_plays, [])
     |> assign_stats()}
  end

  @impl true
  def handle_info({:sound_played, %{filename: filename, played_by: username}}, socket) do
    recent_plays = recent_plays()

    {:noreply,
     socket
     |> stream(:recent_plays, recent_plays, reset: true)
     |> put_flash(:info, "#{username} played #{display_name(filename)}")
     |> clear_flash_after_timeout()}
  end

  # Runs hourly: when a new week starts, a page left on "this week" follows it.
  @impl true
  def handle_info(:check_week_rollover, socket) do
    current_week = get_week_range()

    if current_week == socket.assigns.current_week do
      {:noreply, socket}
    else
      selected =
        if socket.assigns.selected_week == socket.assigns.current_week,
          do: current_week,
          else: socket.assigns.selected_week

      {:noreply,
       socket
       |> assign(:current_week, current_week)
       |> assign(:selected_week, selected)
       |> assign_stats()}
    end
  end

  @impl true
  def handle_info({:stats_updated}, socket) do
    {:noreply, assign_stats(socket)}
  end

  @impl true
  def handle_info({:error, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> clear_flash_after_timeout()}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  defp assign_stats(socket) do
    {start_date, end_date} = socket.assigns.selected_week
    top_users = Stats.get_top_users(start_date, end_date, limit: @recent_limit)
    top_sounds = Stats.get_top_sounds(start_date, end_date, limit: @recent_limit)

    recent_plays = recent_plays()

    recent_uploads = Sounds.get_recent_uploads(limit: @recent_limit)
    favorites = get_favorites(socket.assigns.current_user)
    sound_ids_by_filename = load_sound_ids_by_filename(top_sounds, recent_plays, recent_uploads)
    avatars_by_username = load_avatars_by_username(top_users, recent_plays, recent_uploads)

    socket
    |> assign(:top_users, top_users)
    |> assign(:top_sounds, top_sounds)
    |> stream(:recent_plays, recent_plays, reset: true)
    |> assign(:recent_uploads, recent_uploads)
    |> assign(:favorites, favorites)
    |> assign(:sound_ids_by_filename, sound_ids_by_filename)
    |> assign(:avatars_by_username, avatars_by_username)
  end

  defp get_favorites(nil), do: []
  defp get_favorites(user), do: Favorites.list_favorites(user.id)

  attr :id, :string, required: true
  attr :at, NaiveDateTime, required: true

  # Rendered in UTC, then shown in the viewer's time zone by the LocalTime hook.
  defp played_at(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(DateTime.from_naive!(@at, "Etc/UTC"))}
      phx-hook="LocalTime"
      class="text-xs text-gray-500 dark:text-gray-400 whitespace-nowrap"
    >
      {Calendar.strftime(@at, "%b %d, %H:%M UTC")}
    </time>
    """
  end

  attr :username, :string, required: true
  attr :src, :string, default: nil

  # Discord avatar when known, otherwise the first letter, never a broken image.
  defp avatar(assigns) do
    ~H"""
    <img :if={@src} src={@src} class="w-8 h-8 rounded-full" alt="" />
    <span
      :if={!@src}
      class="w-8 h-8 rounded-full bg-gray-200 dark:bg-gray-600 text-gray-700 dark:text-gray-200 flex items-center justify-center text-sm font-semibold"
      aria-hidden="true"
    >
      {@username |> to_string() |> String.first() |> to_string() |> String.upcase()}
    </span>
    """
  end

  attr :sound, :string, required: true
  attr :favorite, :boolean, required: true

  defp heart(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_favorite"
      phx-value-sound={@sound}
      phx-stop
      aria-pressed={to_string(@favorite)}
      aria-label={
        if @favorite,
          do: "Remove #{display_name(@sound)} from favorites",
          else: "Add #{display_name(@sound)} to favorites"
      }
      class="stats-heart"
    >
      <.icon :if={@favorite} name="hero-heart-solid" class="h-5 w-5 text-red-500" />
      <.icon :if={!@favorite} name="hero-heart" class="h-5 w-5" />
    </button>
    """
  end

  defp get_week_range(date \\ Date.utc_today()) do
    days_since_monday = Date.day_of_week(date, :monday)
    start_date = Date.add(date, -days_since_monday + 1)
    end_date = Date.add(start_date, 6)
    {start_date, end_date}
  end

  defp format_date_range({start_date, end_date}) do
    "#{Calendar.strftime(start_date, "%b %d")} - #{Calendar.strftime(end_date, "%b %d, %Y")}"
  end

  defp date_input_value({start_date, _end_date}) do
    Date.to_iso8601(start_date)
  end

  defp parse_week_input(nil), do: :error
  defp parse_week_input(""), do: :error

  defp parse_week_input(week_value) do
    case Date.from_iso8601(week_value) do
      {:ok, date} -> {:ok, get_week_range(date)}
      _ -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="stats" class="page">
      <div class="page-header">
        <h1 class="page-title">Stats</h1>
        <div class="flex items-center gap-4">
          <button
            phx-click="previous_week"
            aria-label="Previous week"
            class="stats-week-button"
          >
            <.icon name="hero-chevron-left-solid" class="h-5 w-5" />
          </button>
          <div class="flex flex-col items-start gap-1">
            <form
              phx-change="select_week"
              phx-submit="select_week"
              class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
            >
              <label for="week-picker" class="whitespace-nowrap">
                Week of
              </label>
              <input
                type="date"
                id="week-picker"
                name="week"
                value={date_input_value(@selected_week)}
                max={date_input_value(@current_week)}
                phx-debounce="blur"
                class="border border-gray-300 dark:border-gray-600 rounded-md px-2 py-1 bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-200 focus:outline-none focus:ring-2 focus:ring-indigo-500"
              />
            </form>
            <span class="text-xs text-gray-500 dark:text-gray-400">
              {format_date_range(@selected_week)}
            </span>
          </div>
          <button
            phx-click="next_week"
            aria-label="Next week"
            disabled={@selected_week == @current_week}
            class="stats-week-button"
          >
            <.icon name="hero-chevron-right-solid" class="h-5 w-5" />
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
          <h2 class="text-xl font-semibold text-gray-800 dark:text-gray-100 mb-4">Top Users</h2>
          <div class="space-y-2">
            <%= for {username, count} <- @top_users do %>
              <div class="flex justify-between items-center" id={"user-stat-#{slugify(username)}"}>
                <span class={[
                  "px-2 py-1 rounded-full text-sm flex items-center gap-1",
                  get_user_color_from_presence(username, @presences)
                ]}>
                  <img
                    :if={get_user_avatar(username, @presences, @avatars_by_username)}
                    src={get_user_avatar(username, @presences, @avatars_by_username)}
                    class="w-4 h-4 rounded-full"
                    alt={"#{username}'s avatar"}
                  />
                  {username}
                </span>
                <span class="text-gray-600 dark:text-gray-400">{count} plays</span>
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold text-gray-800 dark:text-gray-200 mb-4">Top Sounds</h2>
          <div class="space-y-3">
            <%= for {{sound_name, count}, index} <- Enum.with_index(@top_sounds) do %>
              <div
                class="flex items-center justify-between p-2 px-6 rounded-lg bg-gray-50 dark:bg-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 cursor-pointer group"
                id={"play-top-#{index}"}
                phx-click="play_sound"
                phx-value-sound={sound_name}
              >
                <div class="flex items-center gap-3 min-w-0">
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
                      {display_name(sound_name)}
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {count} plays
                    </p>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <.heart
                    sound={sound_name}
                    favorite={favorite?(@favorites, sound_name, @sound_ids_by_filename)}
                  />
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <div class="mt-8 grid grid-cols-1 md:grid-cols-2 gap-8">
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold text-gray-800 dark:text-gray-200 mb-4">Recent Plays</h2>
          <div class="space-y-3" id="recent_plays" phx-update="stream">
            <%= for {dom_id, play} <- @streams.recent_plays do %>
              <div
                class="flex items-center justify-between p-2 rounded-lg bg-gray-50 dark:bg-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 cursor-pointer group"
                id={dom_id}
                phx-click="play_sound"
                phx-value-sound={play.filename}
              >
                <div class="flex items-center gap-3 min-w-0">
                  <div class="flex-shrink-0">
                    <.avatar
                      username={play.username}
                      src={get_user_avatar(play.username, @presences, @avatars_by_username)}
                    />
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
                      {display_name(play.filename)}
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {play.username}
                    </p>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <.played_at id={"#{dom_id}-at"} at={play.timestamp} />
                  <.heart
                    sound={play.filename}
                    favorite={favorite?(@favorites, play.filename, @sound_ids_by_filename)}
                  />
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold text-gray-800 dark:text-gray-200 mb-4">
            Recently Uploaded
          </h2>
          <div class="space-y-3">
            <%= for {{sound_name, username, timestamp}, index} <- Enum.with_index(@recent_uploads) do %>
              <div
                class="flex items-center justify-between p-2 px-6 rounded-lg bg-gray-50 dark:bg-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 cursor-pointer group"
                id={"play-upload-#{index}"}
                phx-click="play_sound"
                phx-value-sound={sound_name}
              >
                <div class="flex items-center gap-3 min-w-0">
                  <div class="flex-shrink-0">
                    <.avatar
                      username={username}
                      src={get_user_avatar(username, @presences, @avatars_by_username)}
                    />
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
                      {display_name(sound_name)}
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {username}
                    </p>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <.played_at id={"upload-at-#{index}"} at={timestamp} />
                  <.heart
                    sound={sound_name}
                    favorite={favorite?(@favorites, sound_name, @sound_ids_by_filename)}
                  />
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp get_user_color_from_presence(username, presences) do
    presences
    |> Enum.find_value(fn {_id, presence} ->
      meta = List.first(presence.metas)

      if get_in(meta, [:user, :username]) == username do
        get_in(meta, [:user, :color]) ||
          PresenceHandler.get_user_color(username)
      end
    end) || PresenceHandler.get_user_color(username)
  end

  defp handle_favorite_toggle(socket, user, sound_name) do
    case Sounds.fetch_sound_id(sound_name) do
      {:ok, sound_id} -> update_favorite(socket, user, sound_id)
      :error -> {:noreply, put_flash(socket, :error, "Sound not found")}
    end
  end

  defp update_favorite(socket, user, sound_id) do
    case Favorites.toggle_favorite(user.id, sound_id) do
      {:ok, _favorite} ->
        updated_favorites = Favorites.list_favorites(user.id)
        recent_plays = recent_plays()

        {:noreply,
         socket
         |> assign(:favorites, updated_favorites)
         |> stream(:recent_plays, recent_plays, reset: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Favorites.error_message(reason))}
    end
  end

  defp recent_plays do
    Stats.get_recent_plays(limit: @recent_limit)
    |> Enum.map(&map_recent_play/1)
  end

  defp map_recent_play({id, filename, username, timestamp}) do
    %{
      id: id,
      filename: filename,
      username: username,
      timestamp: timestamp
    }
  end

  defp load_sound_ids_by_filename(top_sounds, recent_plays, recent_uploads) do
    filenames =
      top_sounds
      |> Enum.map(fn {filename, _count} -> filename end)
      |> Kernel.++(Enum.map(recent_plays, & &1.filename))
      |> Kernel.++(Enum.map(recent_uploads, fn {filename, _username, _timestamp} -> filename end))
      |> Enum.uniq()

    case filenames do
      [] ->
        %{}

      _ ->
        Sounds.ids_by_filename(filenames)
    end
  end

  defp load_avatars_by_username(top_users, recent_plays, recent_uploads) do
    usernames =
      top_users
      |> Enum.map(fn {username, _count} -> username end)
      |> Kernel.++(Enum.map(recent_plays, & &1.username))
      |> Kernel.++(Enum.map(recent_uploads, fn {_filename, username, _timestamp} -> username end))
      |> Enum.uniq()

    case usernames do
      [] ->
        %{}

      _ ->
        Accounts.avatars_by_usernames(usernames)
    end
  end

  defp recent_play_dom_id(play) do
    base = slugify(play.filename)
    "recent-play-#{base}-#{play.id}"
  end

  @impl true
  def handle_event("play_sound", %{"sound" => sound_name}, socket) do
    SoundPlayback.play(socket, sound_name)
  end

  @impl true
  def handle_event("toggle_favorite", %{"sound" => sound_name}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in to favorite sounds")}

      user ->
        handle_favorite_toggle(socket, user, sound_name)
    end
  end

  @impl true
  def handle_event("previous_week", _, socket) do
    {start_date, _} = socket.assigns.selected_week
    new_week = get_week_range(Date.add(start_date, -7))

    {:noreply,
     socket
     |> assign(:selected_week, new_week)
     |> assign_stats()}
  end

  @impl true
  def handle_event("next_week", _, socket) do
    {start_date, _} = socket.assigns.selected_week
    new_week = get_week_range(Date.add(start_date, 7))

    case Date.compare(elem(new_week, 1), elem(socket.assigns.current_week, 1)) do
      :gt -> {:noreply, socket}
      _ -> {:noreply, socket |> assign(:selected_week, new_week) |> assign_stats()}
    end
  end

  @impl true
  def handle_event("select_week", %{"week" => week_value}, socket) do
    current_week = socket.assigns.current_week

    case parse_week_input(week_value) do
      {:ok, new_week} ->
        if Date.compare(elem(new_week, 1), elem(current_week, 1)) == :gt do
          {:noreply, socket}
        else
          {:noreply,
           socket
           |> assign(:selected_week, new_week)
           |> assign_stats()}
        end

      :error ->
        {:noreply, socket}
    end
  end

  defp favorite?(favorites, sound_name, sound_ids_by_filename) do
    case Map.get(sound_ids_by_filename, sound_name) do
      nil -> false
      sound_id -> Enum.member?(favorites, sound_id)
    end
  end

  defp get_user_avatar(username, presences, avatars_by_username) do
    presences
    |> Enum.find_value(fn {_id, presence} ->
      meta = List.first(presence.metas)
      if get_in(meta, [:user, :username]) == username, do: get_in(meta, [:user, :avatar])
    end) || Map.get(avatars_by_username, username)
  end
end
