defmodule SoundboardWeb.Components.Soundboard.RadioDesk do
  @moduledoc false
  use Phoenix.Component

  attr :volume, :integer, required: true
  attr :capture, :map, required: true
  attr :recordings, :list, required: true

  def radio_desk(assigns) do
    ~H"""
    <section
      aria-label="Radio desk"
      class="mb-8 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-5 space-y-5"
    >
      <div class="flex flex-wrap items-center gap-4">
        <div class="flex-1 min-w-[200px]">
          <label for="master-volume" class="block font-semibold text-gray-800 dark:text-gray-100">
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
            aria-describedby="master-volume-help"
            class="w-full h-10 accent-blue-600"
          />
          <p id="master-volume-help" class="text-sm text-gray-500 dark:text-gray-400">
            Applies to the next sound for everyone in Discord. Clip levels stay unchanged.
          </p>
        </div>
        <button
          type="button"
          phx-click="mute_master"
          disabled={@volume == 0}
          class="min-h-11 px-4 rounded-md bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100 disabled:opacity-50"
        >
          {if @volume == 0, do: "Muted", else: "Mute & stop"}
        </button>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <p id="capture-indicator" class="flex-1 min-w-[200px] text-gray-800 dark:text-gray-100">
          <%= if @capture.target do %>
            <span class="font-semibold text-red-600 dark:text-red-400">● Capture on</span>
            · {@capture.seconds}/60 seconds buffered
          <% else %>
            <span class="font-semibold">Capture off</span>
          <% end %>
        </p>
        <button
          type="button"
          phx-click={if @capture.target, do: "stop_capture", else: "start_capture"}
          class="min-h-11 px-4 rounded-md border border-gray-300 dark:border-gray-600 text-gray-800 dark:text-gray-100"
        >
          {if @capture.target, do: "Stop capture", else: "Start capture"}
        </button>
        <button
          type="button"
          phx-click="save_moment"
          disabled={not @capture.has_audio or @capture.saving}
          class="min-h-11 px-4 rounded-md bg-red-600 hover:bg-red-700 text-white font-semibold disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {if @capture.saving, do: "Saving…", else: "Save last 60 seconds"}
        </button>
      </div>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Captures everyone in the bot's voice channel, including you. Let the group know before starting.
        Unsaved audio expires after a minute. Stop capture discards the buffer.
      </p>
      <details :if={@recordings != []} class="text-sm text-gray-700 dark:text-gray-200">
        <summary class="cursor-pointer py-2 font-medium">
          Saved moments ({length(@recordings)})
        </summary>
        <ul class="mt-2 space-y-2">
          <li :for={name <- Enum.take(@recordings, 30)} class="break-all">
            <a
              href={"/recordings/#{name}"}
              class="text-blue-600 dark:text-blue-300 underline"
              download
            >
              {name}
            </a>
          </li>
        </ul>
        <p class="mt-3">
          Download WAV files to trim after the game, then use Add Sound to upload your clips.
        </p>
      </details>
    </section>
    """
  end
end
