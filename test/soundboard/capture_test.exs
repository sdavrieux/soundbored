defmodule Soundboard.CaptureTest do
  use ExUnit.Case, async: false
  import Mock
  alias Soundboard.{Capture, PubSubTopics}
  alias Soundboard.Discord.Consumer

  setup do
    Capture.stop_capture()
    :ok
  end

  test "capture is opt-in and ignores audio while off" do
    Capture.ingest(%{guild_id: "g", user_id: "u", opus: <<0xF8, 0xFF, 0xFE>>})
    refute Capture.status().has_audio
    assert {:error, :inactive} = Capture.save()
  end

  test "requires a ready voice connection" do
    with_mock Soundboard.Discord.Handler, get_current_voice_channel: fn -> nil end do
      assert {:error, :voice_unavailable} = Capture.start_capture()
      assert Capture.status().target == nil
    end
  end

  test "failed voice negotiation leaves capture off" do
    with_mocks([
      {Soundboard.Discord.Handler, [], [get_current_voice_channel: fn -> {"g", "c"} end]},
      {Soundboard.Discord.Voice, [], [ready?: fn _ -> exit(:voice_unavailable) end]}
    ]) do
      assert {:error, :voice_unavailable} = Capture.start_capture()
      assert Capture.status().target == nil
    end
  end

  test "tick detects a dropped connection and discards unsaved audio even if stopping fails" do
    with_mocks([
      {Soundboard.Discord.Handler, [], [get_current_voice_channel: fn -> {"g", "c"} end]},
      {Soundboard.Discord.Voice, [],
       [
         ready?: fn _ -> true end,
         channel_id: fn _ -> "c" end,
         start_listening: fn _ -> :ok end,
         stop_listening: fn _ -> exit(:connection_lost) end
       ]}
    ]) do
      assert :ok = Capture.start_capture()
      assert :ok = Capture.start_capture()
      assert Capture.active?("g")
      refute Capture.active?("other")
      Capture.ingest(%{guild_id: "g", user_id: "a", opus: <<0xF8, 0xFF, 0xFE>>})
      Capture.channel_changed("other", nil)
      send(Process.whereis(Capture), :tick)
      assert Capture.status().has_audio
      :meck.expect(Soundboard.Discord.Voice, :ready?, fn _ -> false end)
      send(Process.whereis(Capture), :tick)
      assert Capture.status().target == nil
      refute Capture.status().has_audio
    end
  end

  test "a failed export clears saving state and reports an error" do
    PubSubTopics.subscribe_desk()

    with_mocks([
      {Soundboard.Discord.Handler, [], [get_current_voice_channel: fn -> {"g", "c"} end]},
      {Soundboard.Discord.Voice, [],
       [
         ready?: fn _ -> true end,
         channel_id: fn _ -> "c" end,
         start_listening: fn _ -> :ok end,
         stop_listening: fn _ -> :ok end
       ]},
      {Capture.Storage, [], [save: fn _ -> exit(:export_failed) end]}
    ]) do
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Capture.start_capture()
        Capture.ingest(%{guild_id: "g", user_id: "a", opus: <<0xF8, 0xFF, 0xFE>>})
        assert :ok = Capture.save()
        assert_receive {:capture_saved, {:error, :export_failed}}
        refute Capture.status().saving
        Capture.stop_capture()
      end)
    end
  end

  test "export uses a snapshot while capture continues, and concurrent saves are rejected" do
    test_pid = self()
    PubSubTopics.subscribe_desk()

    with_mocks([
      {Soundboard.Discord.Handler, [], [get_current_voice_channel: fn -> {"g", "c"} end]},
      {Soundboard.Discord.Voice, [],
       [
         ready?: fn _ -> true end,
         channel_id: fn _ -> "c" end,
         start_listening: fn _ -> :ok end,
         stop_listening: fn _ -> :ok end
       ]},
      {Capture.Storage, [],
       [
         save: fn snapshot ->
           send(test_pid, {:export_snapshot, snapshot, self()})

           receive do
             :finish_export -> {:ok, "saved.wav"}
           end
         end
       ]}
    ]) do
      assert :ok = Capture.start_capture()
      Capture.ingest(%{guild_id: "g", user_id: "a", opus: <<0xF8, 0xFF, 0xFE>>})
      assert :ok = Capture.save()
      assert_receive {:export_snapshot, snapshot, worker}
      assert length(snapshot.frames) == 1
      Capture.ingest(%{guild_id: "g", user_id: "b", opus: <<0xF8, 0xFF, 0xFE>>})
      assert Capture.status().has_audio
      assert {:error, :saving} = Capture.save()
      send(worker, :finish_export)
      assert_receive {:capture_saved, {:ok, "saved.wav"}}
      refute Capture.status().saving
      Capture.stop_capture()
    end
  end

  test "receives everyone in the connected guild and clears on channel switch" do
    PubSubTopics.subscribe_desk()

    with_mocks([
      {Soundboard.Discord.Handler, [], [get_current_voice_channel: fn -> {"g", "c"} end]},
      {Soundboard.Discord.Voice, [],
       [
         ready?: fn _ -> true end,
         channel_id: fn _ -> "c" end,
         start_listening: fn _ -> :ok end,
         stop_listening: fn _ -> :ok end
       ]}
    ]) do
      assert :ok = Capture.start_capture()
      assert_receive {:capture_status, %{target: {"g", "c"}}}
      assert {:error, :empty} = Capture.save()
      Capture.ingest(%{guild_id: "other", user_id: "a", opus: <<0xF8, 0xFF, 0xFE>>})
      refute Capture.status().has_audio

      for user <- ["a", "b"] do
        Consumer.handle_event(
          {:VOICE_AUDIO,
           %EDA.Event.VoiceAudio{guild_id: "g", user_id: user, opus: <<0xF8, 0xFF, 0xFE>>}}
        )
      end

      assert Capture.status().has_audio
      Capture.channel_changed("g", "new")
      assert Capture.status().target == nil
      refute Capture.status().has_audio
      assert :ok = Capture.start_capture()
      Capture.stop_capture()
      refute Capture.status().has_audio
    end
  end
end
