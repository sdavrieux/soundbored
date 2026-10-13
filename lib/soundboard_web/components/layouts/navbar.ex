defmodule SoundboardWeb.Components.Layouts.Navbar do
  @moduledoc """
  The navbar component.
  """
  use Phoenix.LiveComponent
  use SoundboardWeb, :html

  @impl true
  def render(assigns) do
    ~H"""
    <aside id="studio-sidebar" class="studio-sidebar" phx-hook="Sidebar">
      <div class="sidebar-header">
        <.link navigate="/" class="sidebar-brand">SoundBored</.link>
        <button
          type="button"
          class="sidebar-toggle"
          aria-label="Collapse sidebar"
          aria-expanded="true"
          aria-controls="studio-navigation"
          data-sidebar-toggle
        >
          <.icon name="hero-bars-3" class="h-6 w-6" />
        </button>
      </div>
      <nav id="studio-navigation" aria-label="Main navigation" class="sidebar-links">
        <.link
          :for={
            {path, label, icon} <- [
              {"/", "Sounds", "hero-squares-2x2"},
              {"/moments", "Saved moments", "hero-scissors"},
              {"/favorites", "Favorites", "hero-heart"},
              {"/stats", "Stats", "hero-chart-bar"},
              {"/settings", "Settings", "hero-cog-6-tooth"}
            ]
          }
          navigate={path}
          aria-current={if @current_path == path, do: "page", else: nil}
          title={label}
          aria-label={label}
          class={["sidebar-link", @current_path == path && "is-active"]}
        >
          <.icon name={icon} class="h-6 w-6 shrink-0" /><span class="sidebar-label">{label}</span>
        </.link>
      </nav>
      <div class="sidebar-presences" aria-label="Online users">
        <span
          :for={user <- visible_users(@presences)}
          id={"user-#{user.username}"}
          data-username={user.username}
          class="flex items-center gap-2 py-2 text-sm"
        >
          <img
            :if={is_binary(user.avatar) and user.avatar != ""}
            src={user.avatar}
            class="w-6 h-6 rounded-full"
            alt=""
          /><span
            :if={not is_binary(user.avatar) or user.avatar == ""}
            class="w-6 h-6 rounded-full bg-gray-700 text-center"
            aria-hidden="true"
          >{String.first(user.username)}</span>{user.username}
        </span>
      </div>
    </aside>
    """
  end

  defp visible_users(presences) do
    presences
    |> Enum.flat_map(fn {_id, presence} ->
      Enum.map(presence.metas, & &1.user)
    end)
    |> Enum.uniq_by(& &1.username)
  end
end
