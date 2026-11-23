defmodule Soundboard.Capture.AnalysisTest do
  use ExUnit.Case, async: true
  alias Soundboard.Capture.Analysis

  # Envelopes are 20 ms windows: 50 per second.
  defp level(power, seconds), do: List.duplicate(power, round(seconds * 50))

  test "envelope measures each 20 ms window" do
    loud = :binary.copy(<<16_384::little-signed-16>>, 960)
    quiet = :binary.copy(<<0::16>>, 960)
    assert [loud_power, +0.0] = Analysis.envelope(loud <> quiet)
    assert_in_delta loud_power, 0.25, 0.001
  end

  test "speech bounds keep a little room and ignore silence and lone clicks" do
    env = level(0.0, 1) ++ level(0.01, 1) ++ level(0.0, 1)
    assert Analysis.speech_bounds(env, 3.0) == {0.75, 2.5}
    assert Analysis.speech_bounds(level(0.0, 3), 3.0) == nil
    assert Analysis.speech_bounds(level(0.0, 1) ++ [0.5] ++ level(0.0, 1), 2.02) == nil
  end

  test "a shout over normal speech is a highlight with lead-in" do
    env = level(0.001, 5) ++ level(0.1, 1) ++ level(0.001, 4)

    assert [%{loud: true, voices: 1} = highlight] = Analysis.highlights([env], 10.0)
    assert highlight.at == 5.0
    assert highlight.start == 3.0
    assert highlight.stop == 7.0
  end

  test "several people talking at once is a highlight, steady talk is not" do
    ana = level(0.001, 10)
    ben = level(0.0, 4) ++ level(0.001, 1) ++ level(0.0, 5)

    assert [%{voices: 2, loud: false, at: 4.0}] = Analysis.highlights([ana, ben], 10.0)
    assert Analysis.highlights([ana], 10.0) == []
    assert Analysis.highlights([level(0.0, 10)], 10.0) == []
  end
end
