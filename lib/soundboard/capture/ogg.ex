defmodule Soundboard.Capture.Ogg do
  @moduledoc """
  Wraps received Opus in Ogg for FFmpeg, preserving gaps with 20 ms silence packets.
  See RFC 6716 section 3.1 and RFC 7845. Arrival timing is approximate.
  """
  import Bitwise
  @silence <<0xF8, 0xFF, 0xFE>>

  # EDA 0.1.3 can forward the original frame after a failed DAVE decryption.
  # Discard frames carrying its encrypted-frame marker rather than exporting noise.
  def packet_samples(packet) when is_binary(packet) and byte_size(packet) >= 2 do
    if binary_part(packet, byte_size(packet) - 2, 2) == <<0xFA, 0xFA>>,
      do: :error,
      else: decoded_samples(packet)
  end

  def packet_samples(_), do: :error

  defp decoded_samples(<<toc, rest::binary>>) do
    config = toc >>> 3
    code = toc &&& 3

    samples = frame_samples(config)
    count = frame_count(code, rest)

    if byte_size(rest) > 0 and count > 0 and samples * count <= 5760,
      do: samples * count,
      else: :error
  end

  defp frame_samples(config) when config >= 16, do: 120 <<< rem(config, 4)
  defp frame_samples(config) when config >= 12, do: 480 <<< rem(config, 2)
  defp frame_samples(config) when rem(config, 4) == 3, do: 2880
  defp frame_samples(config), do: 480 <<< rem(config, 4)

  defp frame_count(0, _), do: 1
  defp frame_count(3, <<n, _::binary>>), do: n &&& 63
  defp frame_count(3, _), do: 0
  defp frame_count(_, _), do: 2

  def stream(frames, start, serial) do
    head = <<"OpusHead", 1, 2, 0::little-16, 48_000::little-32, 0::little-16, 0>>
    tags = <<"OpusTags", 0::little-32, 0::little-32>>
    headers = [page(head, 2, 0, serial, 0), page(tags, 0, 0, serial, 1)]

    {pages, samples, sequence} =
      Enum.reduce(frames, {[], 0, 2}, fn {time, _, packet}, acc ->
        duration = packet_samples(packet)
        target = max(0, (time - start) * 48 - duration)
        acc = pad(acc, target, serial)
        {pages, granule, seq} = acc
        {[page(packet, 0, granule + duration, serial, seq) | pages], granule + duration, seq + 1}
      end)

    IO.iodata_to_binary([headers, Enum.reverse(pages), page(<<>>, 4, samples, serial, sequence)])
  end

  defp pad({pages, samples, seq}, target, serial) when samples + 960 <= target do
    pad(
      {[page(@silence, 0, samples + 960, serial, seq) | pages], samples + 960, seq + 1},
      target,
      serial
    )
  end

  defp pad(acc, _, _), do: acc

  defp page(packet, flags, granule, serial, seq) do
    lacing =
      if packet == <<>>,
        do: [],
        else: List.duplicate(255, div(byte_size(packet), 255)) ++ [rem(byte_size(packet), 255)]

    data =
      IO.iodata_to_binary([
        <<"OggS", 0, flags, granule::little-64, serial::little-32, seq::little-32, 0::32,
          length(lacing)>>,
        lacing,
        packet
      ])

    <<prefix::binary-size(22), _::32, suffix::binary>> = data
    <<prefix::binary, crc(data)::little-32, suffix::binary>>
  end

  defp crc(data) do
    for <<byte <- data>>, reduce: 0 do
      crc ->
        Enum.reduce(1..8, bxor(crc, byte <<< 24), &crc_bit/2)
    end
  end

  defp crc_bit(_, value) do
    next = if (value &&& 0x80000000) != 0, do: bxor(value <<< 1, 0x04C11DB7), else: value <<< 1
    next &&& 0xFFFFFFFF
  end
end
