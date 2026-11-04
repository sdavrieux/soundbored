defmodule SoundboardWeb.Components.Soundboard.RadioDesk do
  @moduledoc false
  use Phoenix.Component
  import SoundboardWeb.CoreComponents, only: [icon: 1]
  alias Phoenix.LiveView.JS

  attr :volume, :integer, required: true
  attr :capture, :map, required: true
  attr :naming, :map, default: nil

  def radio_desk(assigns) do
    ~H"""
    <section class="studio-controls" aria-label="Playback controls">
      <div class="master-control">
        <label for="master-volume">
          <span><.volume_icon volume={@volume} /> Master volume</span>
          <span id="master-volume-value">{@volume}%</span>
        </label>
        <input
          id="master-volume"
          type="range"
          min="0"
          max="100"
          step="1"
          value={@volume}
          phx-hook="MasterVolume"
          aria-label="Master volume"
        />
      </div>
      <div class="desk-buttons">
        <button
          :if={!@capture.target}
          id="capture-toggle"
          type="button"
          phx-click="start_capture"
          class="studio-button capture-button"
          title="Keep the last minute of the voice channel in memory"
        >
          <span class="capture-dot is-off" aria-hidden="true"></span> Start capture
        </button>
        <button
          :if={@capture.target}
          id="capture-toggle"
          type="button"
          phx-click="stop_capture"
          data-confirm="Stop capture? Audio that is not saved yet will be discarded."
          class="studio-button capture-button is-live"
          aria-label={"Capturing, #{@capture.seconds} of 60 seconds buffered. Stop capture"}
        >
          <span class="capture-dot" aria-hidden="true"></span>
          <span id="capture-indicator">{@capture.seconds}/60s</span>
        </button>
        <button
          type="button"
          phx-click="save_moment"
          disabled={not @capture.has_audio or @capture.saving}
          class="studio-button save-button"
          title={if @capture.target, do: "Save the last 60 seconds", else: "Start capture first"}
        >
          <.icon name="hero-bookmark-solid" class="w-5 h-5" />
          {if @capture.saving, do: "Saving…", else: "Save last 60s"}
        </button>
        <button
          type="button"
          phx-click="stop_sound"
          class="studio-button stop-button"
          aria-label="Stop all sounds"
        >
          <.icon name="hero-stop-solid" class="w-5 h-5" /> Stop
        </button>
      </div>
      <span class="sr-only" aria-live="polite">
        {if @capture.target, do: "Capture on", else: "Capture off"}
      </span>
    </section>
    <.name_sheet :if={@naming} naming={@naming} />
    """
  end

  attr :volume, :integer, required: true

  defp volume_icon(assigns) do
    ~H"""
    <.icon
      name={if @volume == 0, do: "hero-speaker-x-mark", else: "hero-speaker-wave"}
      class="w-4 h-4 inline-block align-[-3px]"
    />
    """
  end

  attr :naming, :map, required: true

  # Opens the moment Save was pressed: the audio is already frozen and exporting,
  # so naming it here never delays or changes what was captured.
  defp name_sheet(assigns) do
    ~H"""
    <div
      id="name-moment-sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/50"
      phx-window-keydown="skip_naming"
      phx-key="Escape"
    >
      <form
        id="name-moment"
        phx-submit="name_moment"
        role="dialog"
        aria-modal="true"
        aria-labelledby="name-moment-title"
        class="w-full sm:max-w-md max-h-[90vh] overflow-y-auto rounded-t-2xl sm:rounded-2xl p-5
               pb-[calc(20px+env(safe-area-inset-bottom))] space-y-4 shadow-xl
               bg-white text-gray-900 dark:bg-gray-800 dark:text-gray-100"
      >
        <div>
          <h2 id="name-moment-title" class="text-lg font-semibold">Name this moment</h2>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-300">
            The last 60 seconds are being saved. Trim it later in Saved moments.
          </p>
        </div>
        <label class="block text-sm font-medium">
          Name
          <input
            id="name-moment-title-input"
            name="moment[title]"
            maxlength="100"
            autocomplete="off"
            placeholder="e.g. Sam's clutch save"
            phx-mounted={JS.focus()}
            class="field mt-1"
          />
        </label>
        <fieldset :if={@naming.suggestions != []}>
          <legend class="text-sm font-medium">Tags</legend>
          <div class="mt-2 flex flex-wrap gap-2">
            <label :for={tag <- @naming.suggestions} class="cursor-pointer">
              <input type="checkbox" name="moment[tags][]" value={tag} class="peer sr-only" />
              <span class="inline-flex min-h-[36px] items-center rounded-full border px-3 text-sm
                           border-gray-300 text-gray-700 dark:border-gray-600 dark:text-gray-200
                           peer-checked:border-blue-600 peer-checked:bg-blue-600 peer-checked:text-white
                           peer-focus-visible:ring-2 peer-focus-visible:ring-blue-500">
                {tag}
              </span>
            </label>
          </div>
        </fieldset>
        <label class="block text-sm font-medium">
          {if @naming.suggestions == [], do: "Tags", else: "New tags"}
          <input
            name="moment[new_tags]"
            autocomplete="off"
            placeholder="funny, fail, raid"
            class="field mt-1"
          />
          <span class="mt-1 block text-xs font-normal text-gray-500 dark:text-gray-400">
            Separate with commas. Signed-in speakers are tagged automatically.
          </span>
        </label>
        <div class="flex gap-3 pt-1">
          <button
            type="button"
            phx-click="skip_naming"
            class="studio-button btn-secondary flex-1"
          >
            Skip
          </button>
          <button type="submit" class="studio-button btn-primary flex-1">
            Save name
          </button>
        </div>
      </form>
    </div>
    """
  end
end
