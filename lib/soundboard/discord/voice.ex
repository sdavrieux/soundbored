defmodule Soundboard.Discord.Voice do
  @moduledoc false

  alias EDA.Voice, as: EDAVoice
  alias Soundboard.AudioPlayer.LiveStream
  alias Soundboard.MasterVolume

  @connected_error "Must be connected to voice channel to play audio."
  @not_ready_error "Voice session is still negotiating encryption."
  @already_playing_error "Audio already playing in voice channel."

  def join_channel(guild_id, channel_id) do
    voice_module().join(to_id(guild_id), to_id(channel_id))
  end

  def leave_channel(guild_id) do
    voice_module().leave(to_id(guild_id))
  end

  def play(guild_id, input, type, opts \\ []) do
    guild_id = to_id(guild_id)

    {input, type, opts} =
      if voice_module() == EDAVoice and type == :url do
        MasterVolume.sync()

        frames =
          LiveStream.frames(
            input,
            Keyword.get(opts, :clip_volume, Keyword.get(opts, :volume, 1.0))
          )

        {frames, :raw, []}
      else
        {input, type, Keyword.delete(opts, :clip_volume)}
      end

    case play_with_supported_arity(guild_id, input, type, opts) do
      :ok -> :ok
      {:error, :already_playing} -> {:error, @already_playing_error}
      {:error, :not_connected} -> {:error, @connected_error}
      {:error, :not_ready} -> {:error, @not_ready_error}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def stop(guild_id) do
    voice_module().stop(to_id(guild_id))
  end

  def ready?(guild_id) do
    voice_module().ready?(to_id(guild_id))
  end

  def channel_id(guild_id) do
    voice_module().channel_id(to_id(guild_id))
  end

  def playing?(guild_id) do
    voice_module().playing?(to_id(guild_id))
  end

  def start_listening(guild_id), do: voice_module().start_listening(to_id(guild_id))
  def stop_listening(guild_id), do: voice_module().stop_listening(to_id(guild_id))

  # Compatibility shape for existing RTP probe code.
  def get_voice(guild_id) do
    case voice_module().get_voice_state(to_id(guild_id)) do
      {:ok, %{sequence: seq} = state} -> {:ok, %{rtp_sequence: seq, state: state}}
      {:ok, state} -> {:ok, %{state: state}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_voice_state, other}}
    end
  end

  defp play_with_supported_arity(guild_id, input, type, opts) do
    module = voice_module()

    cond do
      function_exported?(module, :play, 4) ->
        :erlang.apply(module, :play, [guild_id, input, type, opts])

      opts == [] ->
        module.play(guild_id, input, type)

      true ->
        {:error, :volume_options_unsupported}
    end
  end

  defp voice_module do
    Application.get_env(:soundboard, :eda_voice_module, EDAVoice)
  end

  defp to_id(nil), do: nil
  defp to_id(value) when is_integer(value), do: Integer.to_string(value)
  defp to_id(value), do: to_string(value)
end
