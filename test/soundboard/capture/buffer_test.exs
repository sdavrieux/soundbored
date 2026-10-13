defmodule Soundboard.Capture.BufferTest do
  use ExUnit.Case, async: true
  alias Soundboard.Capture.{Buffer, Ogg}
  @silence <<0xF8, 0xFF, 0xFE>>

  test "keeps the last minute across speakers without consuming it on save" do
    buffer =
      %Buffer{}
      |> Buffer.push(0, "a", @silence)
      |> Buffer.push(60_000, "b", @silence)
      |> Buffer.push(60_020, "a", @silence)

    assert {:ok, snapshot} = Buffer.snapshot(buffer, 60_030, 0)
    assert snapshot.start == 30
    assert snapshot.frames == [{60_000, "b", @silence}, {60_020, "a", @silence}]
    assert {:ok, ^snapshot} = Buffer.snapshot(buffer, 60_030, 0)
    assert {:error, :empty} = Buffer.snapshot(buffer, 120_021, 0)
  end

  test "bounds memory even if incoming packets all share a timestamp" do
    buffer =
      Enum.reduce(1..110_000, %Buffer{}, fn _, acc -> Buffer.push(acc, 0, "a", @silence) end)

    assert buffer.count == 100_000
    assert buffer.bytes == 300_000
  end

  test "ignores unknown speakers, malformed frames and oversized frames" do
    for {speaker, packet} <- [
          {nil, @silence},
          {"a", <<>>},
          {"a", <<3, 0>>},
          {"a", :bad},
          {"a", @silence <> :binary.copy(<<0>>, 5000)}
        ] do
      assert Buffer.push(%Buffer{}, 0, speaker, packet).count == 0
    end

    assert Ogg.packet_samples(@silence) == 960
    assert Ogg.packet_samples(<<0x80, 0>>) == 120
    assert Ogg.packet_samples(<<0x18, 0>>) == 2880
    assert Ogg.packet_samples(<<0xFB, 63>>) == :error
    assert Ogg.packet_samples(<<0xF8, 0, 0xFA, 0xFA>>) == :error
  end

  test "limits the number of tracks per export" do
    buffer =
      Enum.reduce(1..33, %Buffer{}, fn speaker, acc ->
        Buffer.push(acc, 0, to_string(speaker), @silence)
      end)

    assert {:error, :too_many_speakers} = Buffer.snapshot(buffer, 100, 0)
  end
end
