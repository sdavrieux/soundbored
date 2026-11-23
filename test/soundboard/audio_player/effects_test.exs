defmodule Soundboard.AudioPlayer.EffectsTest do
  use ExUnit.Case, async: true
  alias Soundboard.AudioPlayer.Effects

  test "every preset builds a limited, real-time filter chain FFmpeg accepts" do
    ffmpeg = System.find_executable("ffmpeg")
    assert length(Effects.all()) >= 10

    for %{id: id} <- Effects.all() do
      filter = Effects.filter(id)
      assert String.ends_with?(filter, "alimiter=limit=0.9:level=false,arealtime")

      assert {_, 0} =
               System.cmd(ffmpeg, [
                 "-v",
                 "error",
                 "-f",
                 "lavfi",
                 "-i",
                 "sine=frequency=440:duration=0.2",
                 "-af",
                 filter,
                 "-f",
                 "null",
                 "-"
               ]),
             "#{id} filter failed"
    end
  end

  test "unknown effects are rejected" do
    refute Effects.valid?("chipmunk; rm -rf /")
    assert Effects.filter("nope") == nil
    assert Effects.filter(nil) == nil
  end
end
