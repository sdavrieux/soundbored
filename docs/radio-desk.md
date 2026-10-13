# Radio desk

The main board has a shared master volume and an opt-in rolling voice capture.

## Master volume

The 0–100% slider scales each clip's existing volume before the bot sends it to
Discord. A clip at 80% with the master at 50% plays at 40%. All bot playback paths
use this setting, including favorites, API triggers, and join/leave sounds. The
setting persists in SQLite and updates other open boards.

Changes apply when the next clip starts. The voice library configures its FFmpeg
volume filter at playback startup; it cannot change an already playing clip's
gain. **Mute & stop** saves 0% and stops the current clip. Raise the slider to
unmute. Master volume does not change channel participants' voices or browser
previews used to edit individual clips.

## Capture a moment

1. Join a Discord voice channel. Have the bot join with `!join` or play a sound.
2. Let participants know you are enabling capture, then tap **Start capture**.
3. After something memorable happens, tap **Save last 60 seconds**.
4. Open **Saved moments** to download a WAV. Trim it after the game in your audio
   editor, then upload the finished clip with **Add Sound**.

Capture includes incoming voices from everyone in the bot's connected channel,
including the operator. The bot's own sound effects are not part of incoming
voice audio. The master slider does not attenuate captured conversations.

The buffer keeps up to one minute in RAM; only pressing Save writes a recording.
During the first minute, Save exports the time since capture started. Silence
between turns is retained, and overlapping speakers are mixed with a limiter.
Saving leaves capture running and allows later saves to overlap. One export may
run at a time. Capture prevents the playback idle timer from disconnecting the
bot; leaving an empty channel still takes precedence.

**Stop capture**, a bot disconnect, a channel switch, or an application restart
discards unsaved audio. Capture starts off after a restart. Stop does not cancel
a save already in progress. Save stays disabled until at least one voice frame
has arrived. EDA 0.1.3 exposes arrival times rather than RTP timestamps, so
alignment is approximate and network jitter or packet loss can affect recordings.
Frames still bearing the DAVE encryption marker are dropped.

## Private storage

Set `SOUNDBOARD_RECORDINGS_DIR` to a dedicated directory outside `priv/static`.
The default is `priv/recordings` relative to the application working directory.
For containers, mount persistent storage at `/app/priv/recordings` and set the
variable to that path. The container user must be able to write it. Add this
mount alongside the existing upload/database mounts; preserve those mounts.
Include recordings in your private backup plan separately.

Recording directories use mode 700 and saved WAV files use mode 600. Downloads
require the same session, role check, and optional basic auth as the board, with
`private, no-store` cache headers. Recordings are never served as public assets.
Use generated filenames only; path traversal and file symlinks are rejected.
All authorized board operators can access the shared recordings.

The buffer is limited to 16 MiB and 100,000 frames. Exports support up to 32
speakers. The folder allows 200 saved moments (roughly 1.2 GB for 60-second mono
PCM WAV files); archive saved clips privately to make room. The UI lists the
newest 30 downloads. Temporary speaker tracks are removed after export. FFmpeg
exports have a 60-second processing timeout and report failure without exposing
packet data, server paths, or subprocess output to the UI.

Do not put recordings, databases, private environment files, Discord credentials,
or deployment-specific addresses in the public repository. Default recording
storage, databases, and private environment files are excluded from Git and the
Docker build context. Keep an externally configured recording folder outside
the repository as well.

## Validation and rollout

Run `mix test`, `mix credo --strict`, and `mix precommit`. Recording integration
tests require FFmpeg with `libopus`. They generate synthetic tones locally;
Discord credentials are not needed for automated tests. The Docker build uses
the dependency versions in `mix.lock`, including EDA 0.1.3.

Before rollout, validate DAVE negotiation and incoming audio in a private test
guild with two participants, concurrent playback/capture, save during speech,
channel switching, and iPad downloads. Synthetic tests do not establish live
Discord reception or iPad behavior. Build a pinned image from the feature branch
and retain a pre-migration database/configuration backup. The new
`playback_settings` table is additive. Deploy only with the operator's approval;
rollback can reuse the old pinned image and original mounts. Preserve the new
recording mount when rolling back so saved moments remain available privately.
