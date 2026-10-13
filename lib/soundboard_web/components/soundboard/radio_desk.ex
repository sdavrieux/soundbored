defmodule SoundboardWeb.Components.Soundboard.RadioDesk do
  @moduledoc false
  use Phoenix.Component

  attr :volume, :integer, required: true
  attr :capture, :map, required: true

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
    """
  end
end
