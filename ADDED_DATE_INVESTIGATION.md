# `Song.addedDate` population investigation — 2026-04-11

**Author:** implementer-amperfy
**Trigger:** QA report 2026-04-11, Bug B-2 secondary observation ("songs from
recently-added albums may not have `addedDate` populated in Core Data until
individual album detail views are opened").
**Scope:** research only. No code changes in this phase.

---

## TL;DR

The hypothesis holds. `Song.addedDate` is populated in exactly **one place** —
`SsSongParserDelegate.didStartElement`, reading the `created` attribute off
any `<song> / <entry> / <child> / <episode>` element. That parser is only run
on API paths that return *song-level* XML. The bulk album sync path
(`getAlbumList2` → `SsAlbumParserDelegate`) returns album-level XML only and
never parses a single song, so nothing pre-populates song rows at initial
library sync time.

On a fresh install the recent-tracks widget therefore queries a **near-empty
songs table** (the only seeded songs are from `syncFavoriteLibraryElements` +
any backgrounded random-songs pulls), which is why the section renders
nothing until the user has drilled into individual albums.

**Verdict for the build 6 decision:** this is NOT a few-line change and
should NOT ride in build 6. See §5 below. Build 6 ships B-1 + B-2
fixes only; `addedDate` population gets its own dedicated investigation +
PR.

---

## 1. What populates `Song.addedDate`

A single code path. `AmperfyKit/Api/Subsonic/SsSongParserDelegate.swift:134-138`:

```swift
if let createdTag = attributeDict["created"] {
  let dateFormatter = ISO8601DateFormatter()
  dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  songBuffer?.addedDate = dateFormatter.date(from: createdTag)
}
```

This runs inside the handler that matches element names
`song | entry | child | episode`, i.e. whenever the XML response carries a
song child element. The wrapper setter at
`AmperfyKit/Storage/EntityWrappers/Song.swift:addedDate` is a straight
pass-through to `managedObject.addedDate`, no computed fallback.

There is no bulk-backfill job, no migration that derives `addedDate` from
anything else, and no client-side synthesis from `Album.year` or similar.
If the server does not include the `created` attribute in the song element,
`addedDate` stays `nil` for that song forever unless it is re-parsed from a
later response that *does* include it.

## 2. What the bulk album sync does

`SubsonicLibrarySyncer.syncAlbums` (line 124-161) and `syncNewestAlbums` /
`syncRecentAlbums` (lines 636-703) all use **only** `SsAlbumParserDelegate`.
That parser (`AmperfyKit/Api/Subsonic/SsAlbumParserDelegate.swift`) processes
`<album>` start/end elements and never opens a `<song>` element — it never
reads the `created` attribute and never instantiates `SsSongParserDelegate`.

Consequence: every code path below populates zero songs and zero
`addedDate`s:

- `syncAlbums` (initial bulk library pull) — `getAlbumList2` via
  `requestAlbums(offset:count:)` in a paged loop.
- `syncNewestAlbums` — `getAlbumList2?type=newest` (Home "Newest Albums"
  feed).
- `syncRecentAlbums` — `getAlbumList2?type=recent` (Home "Recently Played"
  feed).
- `syncLatestLibraryElements` album-only branches.

So after a fresh install and the default startup sync, the songs table
contains **only** whatever was brought in by the paths in §3 below. In the
typical case of a brand-new account whose user has not starred anything yet
and has not drilled into an album, the songs table is empty.

## 3. What the per-album and song-level syncs do

The paths that *do* populate `Song.addedDate`:

- `syncAlbumSongs(album:)` at line 363-432 — `getAlbum?id=…`. This is the
  "user opened an album detail page" path. Runs `SsAlbumParserDelegate` *then*
  `SsSongParserDelegate` over the same response, so every song child gets its
  `created` attribute read.
- `syncFavoriteLibraryElements` at line 706-752 — `getStarred` response is
  parsed by Artist + Album + Song delegates. Favorite songs get `addedDate`
  set.
- `requestRandomSongs` at line 877-905 — `getRandomSongs`, parsed by
  `SsSongParserDelegate`.
- `requestSimilarSongs` at line 908+ — `getSimilarSongs`, same parser.
- `search3` / `search2` paths around line 1289 — `SsSongParserDelegate`.

Of these, only `syncFavoriteLibraryElements` is part of the *default*
post-login sync sequence. Everything else is triggered by explicit user
action (tap album, tap song, run search, play random). On a fresh install
with no starred favorites, zero songs land in Core Data from the initial
sync — which matches the observed B-2 repro ("no track rows visible below
the header").

## 4. Hypothesis verdict

**Confirmed.** The B-2 secondary observation in the QA report is correct in
all its load-bearing claims:

1. `addedDate` is set only from server-side `created`.
2. Only song-level XML paths run the song parser.
3. `getAlbumList2` does not return song-level XML, so bulk album sync never
   populates songs.
4. The widget's post-sync empty state is therefore the expected consequence
   of the current sync architecture, not a bug in the widget query or the
   predicate.

There are also two *corollary* failure modes worth flagging:

- **Server-side `created` missing.** Even when `syncAlbumSongs` runs, if the
  Subsonic / Navidrome server omits the `created` attribute on its song
  children the wrapper setter is never called and `addedDate` stays nil.
  Navidrome's OpenSubsonic implementation does emit `created`, so in
  practice this is not the main failure mode against our QA server, but it
  is a latent risk against other servers — no defensive fallback exists.
- **Stale song rows re-read without `created`.** If a song is first seen in
  a response that *did* emit `created`, is persisted with a non-nil
  `addedDate`, and is then re-parsed from a later response that *omits*
  `created`, the parser silently skips the assignment (the
  `if let createdTag` branch is never taken). This is actually the correct
  behavior — existing data is preserved — but it means recovery from a
  bulk-sync that lost timestamps is non-trivial.

## 5. Bug #23 implications

Team-lead brief cites "Bug #23: blank album tracks on freshly-added
Navidrome album" as a potential sibling bug. Bug #23 is not in the
2026-04-11 QA report so I am working from the brief's one-line description.

Two candidate mechanisms, in descending order of confidence:

**Candidate A (medium confidence):** The same `addedDate` nil state affects
the detail VC indirectly. `syncAlbumSongs` runs on album-open, which parses
songs with a `created` attribute and sets `addedDate`. A freshly-added
album's songs on Navidrome *should* always have a non-nil `created` server
side. Unless the album open path fails before the song parser runs (e.g.
the server returns an album stub with no song children for an album that
Navidrome has not finished scanning), the detail VC would show the songs
with a valid `addedDate`. The "blank album tracks" symptom doesn't
line up neatly with this mechanism — blank tracks usually means "no rows"
not "rows with nil timestamps".

**Candidate B (lower confidence, but plausible):** Freshly-added Navidrome
albums may trigger `syncAlbumSongs`, hit a race where Navidrome returns an
album record before its scanner has indexed the child songs, and land in
Core Data with `isSongsMetaDataSynced = true` but zero songs. Subsequent
drills into the album short-circuit because the flag says "already synced".
This would present as "blank album tracks" and would not be fixable by any
`addedDate` work — it needs a re-sync trigger (invalidate
`isSongsMetaDataSynced` after N minutes, or when `remoteSongCount !=
songs.count`, or explicit pull-to-refresh).

Either way, Bug #23 is **not** the same bug as B-2 and should not be
bundled into the same fix. If team-lead has a concrete Bug #23 repro we can
grab the diagnostic evidence in a dedicated session; until then it stays on
the backlog as its own investigation.

## 6. Recommended fix scope (if/when this becomes a ticket)

A correct fix has to seed the songs table at initial-sync time with enough
rows for the recent-tracks widget to find material. Options, in rough
order of cost:

1. **`search3` cold-seed after `syncAlbums`.** Issue a single paged
   `search3?query="" &songCount=50&songOffset=…` (or a Navidrome-specific
   equivalent) and run `SsSongParserDelegate` over the response. One new
   call, one new helper on `SubsonicLibrarySyncer`, no schema changes. The
   main unknowns are: (a) whether every target server honors empty-query
   `search3`, (b) whether 50 rows is enough for the widget's "last 7 days"
   mode on heavily-stocked libraries, (c) how to gate this so existing
   installs don't re-cold-seed on every launch.
2. **Chained `getAlbum` on the top-N newest albums after
   `syncNewestAlbums`.** More accurate for the widget's use case (songs
   from the actual newest albums will be the answer 95% of the time), but
   costs N extra round trips on every Home-tab sync. Rate-limiting and
   backoff need design; we'd probably want this to run only once after
   initial bulk sync.
3. **Sync the full song table in the background.** Correct but expensive —
   large libraries (50k+ songs) would generate thousands of parse events.
   Needs pagination, throttling, and progress reporting. Out of scope for
   a single fix.

Every option requires at least: one new parser call-site, a
`SubsonicLibrarySyncer` method, call-site wiring from the post-login sync
sequence, a feature flag to gate the extra traffic for users on expensive
connections, and a test. The smallest realistic PR is probably option 1
plus a `UserDefault`-backed "did cold-seed once" flag.

**None of this is a few-line change.** None of it is zero-regression-risk —
any extra sync call introduces new error surfaces (timeout handling,
server-specific edge cases, cache invalidation). Adding it under the build
6 wire is not advisable.

## 7. Decision

Ship build 6 with Phase 1 (B-1) and Phase 2 (B-2 cosmetic) only. File a
dedicated backlog ticket for the `addedDate` cold-seed work and link this
document as the investigation record. Bug #23 gets its own investigation
task once we have a repro or clearer description.
