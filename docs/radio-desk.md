# Radio desk

The sidebar opens Sounds, Saved moments, Favorites, Stats, and Settings. A fixed
bottom bar keeps master volume, Stop, and Save last 60 seconds within reach.
Start capture sits beside Add Sound and Play Random on the Sounds page.
Use the sidebar toggle to switch between full navigation and an icon rail. Your
choice is remembered in this browser; content and bottom controls expand with it.
On phones, expanding the rail opens navigation over the content.

## Master volume

The 0–100% slider scales each clip's existing volume before the bot sends it to
Discord. A clip at 80% with the master at 50% plays at 40%. All bot playback paths
use this setting, including favorites, API triggers, and join/leave sounds. The
setting persists in SQLite and updates other open boards.

Changes apply to a playing clip as well as the next one. Discord playback decodes
into bounded PCM chunks, applies the current master multiplier, and streams Opus
through EDA's existing encryption and RTP sender. Encoder buffering introduces a
short delay before a change is heard. Browser previews use Web Audio gain so the
slider also works on iPad, where setting an audio element's volume is unreliable.
Remote preview URLs must allow CORS. The master does not change participants'
voices or the stored recordings. **Stop** stops Discord and browser playback.

The pinned EDA 0.1.3 dependency documents raw Enumerable input but only accepts
lists internally. `mix deps.get` runs `scripts/prepare_voice_runtime.exs`, a small
hash-checked compatibility patch that accepts a lazy stream and anchors timing
at its first frame. Dependency updates require reviewing this patch; unexpected
source changes fail rather than applying it blindly. Runtime playback requires
FFmpeg with libopus and Unix `sh`/`mkfifo`, included in the Alpine image.

## Capture a moment

1. Join a Discord voice channel. Have the bot join with `!join` or play a sound.
2. Let participants know you are enabling capture, then tap **Start capture**.
3. After something memorable happens, tap **Save last 60 seconds**.
4. Open **Saved moments** from the sidebar and select a recording.
5. Play it, choose start/end using the sliders or exact second fields, and use
   **Preview selection** to hear the trim.
6. **Save changes** replaces the private recording with the chosen range and
   name. **Publish to Sounds** creates a dashboard sound from the current range,
   leaving the private recording unchanged. Published clips receive a moments tag.
7. **Download WAV** exports a private copy. **Delete moment** asks for confirmation
   and removes the private recording; published dashboard sounds remain separate.

Edits carry a revision check so an older tab cannot overwrite a newer trim.
Invalid ranges, missing clips and duplicate dashboard names produce an error.
The editor supports the mono 48 kHz PCM WAV format produced by capture; trimming
copies exact samples without re-encoding. Title/revision metadata stays beside
recordings in private JSON files.

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
PCM WAV files); archive saved clips privately to make room. The moments page
lists all saved recordings. Temporary speaker tracks are removed after export. FFmpeg
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

The runtime image makes its packaged application files readable by non-root
users even when the build checkout uses restrictive file modes. The entrypoint
uses the compiled application without recompiling it and stops if migrations
fail. Permissions of persistent host mounts are configured separately.

Before rollout, validate DAVE negotiation and incoming audio in a private test
guild with two participants, concurrent playback/capture, save during speech,
channel switching, and iPad downloads. Synthetic audio and local browser tests
do not establish live Discord reception or physical iPad behavior. Build a
pinned image from the feature branch
and retain a pre-migration database/configuration backup. The new
`playback_settings` table is additive. Deploy only with the operator's approval;
rollback can reuse the old pinned image and original mounts. Preserve the new
recording mount when rolling back so saved moments remain available privately.
