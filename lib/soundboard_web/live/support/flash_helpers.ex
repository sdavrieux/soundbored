defmodule SoundboardWeb.Live.Support.FlashHelpers do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]
  import SoundboardWeb.SoundHelpers, only: [display_name: 1]

  def flash_sound_played(socket, %{filename: filename, played_by: username}) do
    socket
    |> put_flash(:info, "#{username} played #{display_name(filename)}")
    |> clear_flash_after_timeout()
  end

  def clear_flash_after_timeout(socket) do
    Process.send_after(self(), :clear_flash, 3000)
    socket
  end
end
