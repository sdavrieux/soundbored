defmodule SoundboardWeb.Components.Soundboard.RadioDesk do
  @moduledoc false
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :volume, :integer, required: true
  attr :capture, :map, required: true
  attr :naming, :map, default: nil

  def radio_desk(assigns) do
    ~H"""
    <section class="studio-controls" aria-label="Playback controls">
      <div class="master-control">
        <label for="master-volume">
          Master volume <span id="master-volume-value">{@volume}%</span>
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
      <button type="button" phx-click="stop_sound" class="studio-button stop-button">Stop</button>
      <button
        type="button"
        phx-click="save_moment"
        disabled={not @capture.has_audio or @capture.saving}
        class="studio-button save-button"
      >
        {if @capture.saving, do: "Saving…", else: "Save last 60 seconds"}
      </button>
      <span id="capture-indicator" class="capture-status" aria-live="polite">
        {if @capture.target, do: "● #{@capture.seconds}/60s", else: "Capture off"}
      </span>
    </section>
    <.name_sheet :if={@naming} naming={@naming} />
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
            class="moment-field mt-1 text-base"
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
            class="moment-field mt-1 text-base"
          />
          <span class="mt-1 block text-xs font-normal text-gray-500 dark:text-gray-400">
            Separate with commas. Signed-in speakers are tagged automatically.
          </span>
        </label>
        <div class="flex gap-3 pt-1">
          <button
            type="button"
            phx-click="skip_naming"
            class="studio-button flex-1 border border-gray-300 dark:border-gray-600"
          >
            Skip
          </button>
          <button type="submit" class="studio-button flex-1 bg-blue-600 text-white">
            Save name
          </button>
        </div>
      </form>
    </div>
    """
  end
end
