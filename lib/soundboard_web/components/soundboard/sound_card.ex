defmodule SoundboardWeb.Components.Soundboard.SoundCard do
  @moduledoc """
  One sound as a pad: tapping the card plays it in Discord, the small buttons
  preview it here, favorite it or edit it. Shared by Sounds and Favorites.
  """
  use SoundboardWeb, :html

  attr :sound, :map, required: true
  attr :favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :show_edit, :boolean, default: true
  attr :selecting, :boolean, default: false
  attr :selectable, :boolean, default: false
  attr :selected, :boolean, default: false

  def sound_card(assigns) do
    assigns =
      assigns
      |> assign(:name, display_name(assigns.sound.filename))
      |> assign(:uploader, uploader(assigns.sound))

    ~H"""
    <div class={[
      "sound-pad",
      @selected && "is-selected",
      @selecting && !@selectable && "opacity-50"
    ]}>
      <button
        :if={@selecting}
        id={"select-sound-#{@sound.id}"}
        phx-click="toggle_select"
        phx-value-id={@sound.id}
        disabled={!@selectable}
        aria-pressed={to_string(@selected)}
        aria-label={"Select #{@name}"}
        class="sound-pad-hit"
      >
      </button>
      <button
        :if={!@selecting}
        phx-click="play"
        phx-value-name={@sound.filename}
        aria-label={"Play #{@name} in Discord"}
        class="sound-pad-hit"
      >
      </button>

      <div class="relative z-10 flex h-full flex-col gap-2 p-3 pointer-events-none">
        <div class="flex items-start gap-2 min-w-0">
          <span
            :if={@selectable}
            class={[
              "mt-0.5 flex h-5 w-5 flex-shrink-0 items-center justify-center rounded border",
              if(@selected,
                do: "bg-red-600 border-red-600 text-white",
                else: "border-gray-400 dark:border-gray-500"
              )
            ]}
          >
            <.icon :if={@selected} name="hero-check" class="w-3.5 h-3.5" />
          </span>
          <div class="min-w-0">
            <p class="sound-pad-name">{@name}</p>
            <p :if={@uploader} class="truncate text-xs text-gray-500 dark:text-gray-400">
              by {@uploader}
            </p>
          </div>
        </div>

        <div class="mt-auto flex justify-end gap-1 pointer-events-auto">
          <button
            id={"local-play-#{Path.basename(@sound.filename, Path.extname(@sound.filename))}"}
            type="button"
            phx-hook="LocalPlayer"
            data-filename={@sound.filename}
            data-source-type={@sound.source_type}
            data-url={@sound.url}
            data-volume={@sound.volume || 1.0}
            aria-label={"Preview #{@name} on this device"}
            title="Preview on this device"
            class="sound-pad-action hover:text-green-600 dark:hover:text-green-400"
          >
            <.icon name="hero-speaker-wave" class="w-5 h-5 play-icon" />
            <.icon name="hero-stop-solid" class="w-5 h-5 stop-icon hidden" />
          </button>
          <button
            :if={@show_favorite}
            type="button"
            phx-click="toggle_favorite"
            phx-value-sound-id={@sound.id}
            aria-pressed={to_string(@favorite)}
            aria-label={
              if @favorite,
                do: "Remove #{@name} from favorites",
                else: "Add #{@name} to favorites"
            }
            class="sound-pad-action hover:text-red-500"
          >
            <.icon :if={@favorite} name="hero-heart-solid" class="w-5 h-5 text-red-500" />
            <.icon :if={!@favorite} name="hero-heart" class="w-5 h-5" />
          </button>
          <button
            :if={@show_edit}
            type="button"
            phx-click="edit"
            phx-value-id={@sound.id}
            aria-label={"Edit #{@name}"}
            class="sound-pad-action hover:text-blue-600 dark:hover:text-blue-400"
          >
            <.icon name="hero-pencil-square" class="w-5 h-5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp uploader(%{user: %{username: name}}) when is_binary(name), do: name
  defp uploader(_), do: nil
end
