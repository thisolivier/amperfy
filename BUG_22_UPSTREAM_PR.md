# Upstream PR body — Bug #22 fix

**Branch:** `bug-22-upstream` (single commit, off `vanilla` which tracks `origin/master`)
**Target:** `BLeeEZ/amperfy` `master`
**Files touched:** 1 (`Amperfy/Screens/Player/PlayerUIHandler.swift`)
**LOC delta:** +26 / -4

---

## Suggested PR title

```
Fix: fall back to persisted track duration when audio engine returns 0
```

## Suggested PR body

### Problem

Intermittently, the player UI renders `--:--` for the total track length
while the elapsed-time label ticks up correctly. The issue is most
reliably reproduced on VBR-encoded tracks, tracks with a slow stream
start, or certain codecs where bitrate estimation takes longer than the
first 1-second UI refresh tick.

### Root cause

`AudioStreaming.AudioPlayer.duration` is a computed value derived from
`AudioEntry.duration()`, which returns `0` until enough audio packets
have been parsed for the engine to compute the track length. Meanwhile
`progress` (the elapsed-frames counter) is available immediately from
the first playback tick.

`PlayerUIHandler.refreshTimeInfo` wires `player.duration` directly into:

- the remaining-time label (`Int(player.elapsedTime - ceil(player.duration))`)
- the slider's `maximumValue` (`Float(player.duration)`)
- the remaining-time recomputation inside `timeSliderIsChanging`

When `player.duration` is `0`, these bindings render as `--:--` /
zero-max slider until the engine catches up — which for short tracks or
slow starts can be most of the way through playback.

`AbstractPlayable.duration` is the Subsonic-parsed, persisted
`combinedDuration` (seconds, `Int16`) that Amperfy already reads from
the `getAlbum` / `getArtist` responses. It is known at playback start
and is a strictly-better fallback than the `--:--` placeholder.

### Fix

Introduce a `private var effectiveDuration: Double` computed property on
`PlayerUIHandler` that prefers `player.duration` when it is a normal
non-zero value and falls back to `Double(player.currentlyPlaying.duration)`
otherwise. All four call sites that previously used `player.duration`
directly are rewritten to read `effectiveDuration`:

- `remainingTime`
- `timeSliderIsChanging` (remaining-time recomputation)
- `refreshTimeInfo` (slider `maximumValue`)

`effectiveDuration` is intentionally a computed property rather than a
cached value — `refreshTimeInfo` is invoked on every 1-second player
tick, so the fallback → engine-value transition happens automatically
as soon as packet parsing completes. No state to invalidate.

### Regression risk

Zero in the common case: when `player.duration` is non-zero and
`.isNormal`, the new path is identical to the old path. The fallback
branch only activates when the previous code would have rendered
`--:--` — i.e. strictly an improvement for every call site.

### Testing notes

I don't have a unit test for this change. `PlayerUIHandler` is not
covered by the existing `AmperfyKitTests` target (it lives in the
`Amperfy` app target, which has no test target), and stubbing the
`AudioStreamingPlayer` behavior would require a non-trivial refactor
that's out of scope for this fix. Verified manually in Simulator
against a Navidrome server by forcing the previously-buggy path on a
VBR MP3: pre-fix renders `--:--` for several seconds; post-fix shows
the persisted duration immediately.

---

## How Olivier can push + open the PR

The fork's `origin` currently points at `BLeeEZ/amperfy` (which we
don't have push access to), so a fork remote needs to be added first:

```bash
cd /Users/olivier/sites/navidromClient/spike/amperfy

# Replace with your actual fork URL
git remote add fork git@github.com:thisolivier/amperfy.git

git push -u fork bug-22-upstream
# Then open the PR via the GitHub web UI or:
gh pr create --repo BLeeEZ/amperfy --base master --head thisolivier:bug-22-upstream \
  --title "Fix: fall back to persisted track duration when audio engine returns 0" \
  --body-file spike/amperfy/BUG_22_UPSTREAM_PR.md
```

The branch is a single commit off `vanilla` (which tracks
`origin/master`) — no spike-specific files, no version bumps, no
entitlements changes, no CocoaPods drift. It is ready to PR as-is.
