defmodule Soundboard.Discord.VoiceTest do
  use ExUnit.Case, async: false

  alias Soundboard.Discord.Voice

  defmodule VoiceModuleWithPlay4 do
    def play(guild_id, input, type, opts) do
      Process.put(:voice_play_args, {guild_id, input, type, opts})
      :ok
    end
  end

  defmodule VoiceModuleWithPlay3 do
    def play(guild_id, input, type) do
      Process.put(:voice_play_args, {guild_id, input, type})
      :ok
    end
  end

  setup do
    previous_module = Application.get_env(:soundboard, :eda_voice_module)
    Process.delete(:voice_play_args)

    on_exit(fn ->
      Process.delete(:voice_play_args)

      if is_nil(previous_module) do
        Application.delete_env(:soundboard, :eda_voice_module)
      else
        Application.put_env(:soundboard, :eda_voice_module, previous_module)
      end
    end)

    :ok
  end

  test "uses play/4 when the configured voice module supports it" do
    Application.put_env(:soundboard, :eda_voice_module, VoiceModuleWithPlay4)

    assert :ok = Voice.play(123, "file.mp3", :url, volume: 1.2)
    assert Process.get(:voice_play_args) == {"123", "file.mp3", :url, [volume: 1.2]}
  end

  test "rejects unsupported volume options rather than silently ignoring the slider" do
    Application.put_env(:soundboard, :eda_voice_module, VoiceModuleWithPlay3)

    assert {:error, ":volume_options_unsupported"} =
             Voice.play(123, "file.mp3", :url, volume: 1.2)

    refute Process.get(:voice_play_args)
    assert :ok = Voice.play(123, "file.mp3", :url)
    assert Process.get(:voice_play_args) == {"123", "file.mp3", :url}
  end
end
