# EDA 0.1.3 documents Enumerable raw input but guards it as a list. Keep its
# encryption/RTP machinery and permit our live encoder stream. Anchor pacing
# when the first encoded packet arrives, so startup never causes a burst.
path = "deps/eda/lib/eda/voice/audio.ex"
original = File.read!(path)
marker = "# SoundBored: lazy raw audio input"
if not String.contains?(original, marker) do
  hash = :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)
  unless hash == "78b6f9654ff8c4d2a8ab4f9b440ba2f58d82772bc3bcdd1e7264655fdfe98214", do: raise("EDA audio source changed; review the streaming compatibility patch")
  old = "defp send_frames(frames, guild_id, voice_state, seq, timestamp, nonce) when is_list(frames) do\n    start = System.monotonic_time(:microsecond)"
  new = marker <> "\n  defp send_frames(frames, guild_id, voice_state, seq, timestamp, nonce) do"
  patched = original |> String.replace(old, new)
    |> String.replace("frame_idx: 0, status: :ok},", "frame_idx: 0, status: :ok, start: nil},")
    |> String.replace("frame, %{seq: s, ts: t, nonce: n, frame_idx: i} = acc ->", "frame, %{seq: s, ts: t, nonce: n, frame_idx: i} = acc ->\n          start = acc.start || System.monotonic_time(:microsecond)")
    |> String.replace("nonce: next_nonce, frame_idx: i + 1}", "nonce: next_nonce, frame_idx: i + 1, start: start}")
  File.write!(path, patched)
end
