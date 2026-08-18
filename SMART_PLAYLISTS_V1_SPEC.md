# Smart Playlists V1 — Design Spec

Feature: local on-device smart playlist query engine ("Fable Amplitude" request, 2026-08-17).
Scope: V1 + side quest (playlist delete). V2 (saved smart playlist list, favourites, Home mixing,
export to regular playlist) ships later — keep naming/architecture V2-friendly.

## User requirements (locked with user)

- Rule-row query builder (Apple-Music style, AND-combined rules).
- "New" = date added to library (server `created` → `Song.addedDate`).
- Play data = server play data, overlaid with local plays newer than the last sync
  (offline plays must be visible immediately — e.g. listening on a bus).
- The generated result list is FROZEN: persists across app launches, never auto-updates.
  Explicit refresh only, via a refresh button under the header preview image.
- Result list is playable like any album/playlist (tap-to-play, skip, back).
- Entry point: a "Smart Playlists" row on the Library tab.
- Side quest: Delete Playlist action in the playlist detail view's top-right ⋯ menu.

## Architecture decisions

### Play data: merge server values into the existing local fields

Amperfy today never parses `playCount`/`played` from the server; `playCount`/`lastPlayedDate`
on `AbstractLibraryEntity` are bumped locally at play start (`AudioPlayer.swift:114` →
`countPlayed()`). Our Navidrome emits `playCount`, `played`, `created` attrs on song XML
(verified in navidrome fork `responses.go`).

Decision — no new CoreData fields (fork convention: avoid schema changes):
- In `SsSongParserDelegate`, parse `playCount` and `played` and merge into the existing fields:
  - `playCount = max(localPlayCount, serverPlayCount)`
  - `lastPlayedDate = later(local, server)`
- Local `countPlayed()` keeps bumping instantly on device → offline plays visible at once;
  server sync later raises the floor with plays from other clients. `max()` never loses either.

### Date parsing bug fix (required)

`SsSongParserDelegate.swift:133-137` uses `ISO8601DateFormatter` with
`[.withInternetDateTime, .withFractionalSeconds]` — fractional seconds become REQUIRED, and
Go's RFC3339 marshaling omits trailing-zero fractions, so many `created` values parse to nil.
Fix: try fractional-seconds formatter first, fall back to plain `.withInternetDateTime`.
Use the same tolerant parsing for the new `played` attr. Keep both formatters as statics
(formatter construction is expensive).

### addedDate sparsity → targeted backfill on refresh

`addedDate` is only set by song-level XML (see `ADDED_DATE_INVESTIGATION.md`); bulk album sync
never populates it. An online refresh therefore does a targeted backfill BEFORE evaluating:
fetch `getAlbumList2 type=newest` pages until album `created` is older than the query's
added-within cutoff (hard caps: ≤ 500 albums / ≤ 10 pages of 50), and sync each such album's
songs via the existing album sync (song XML → populates `addedDate` + play data).
If the query has no added-within rule, skip this step.

### Playlist rules need item-synced playlists

`PlaylistItemMO` rows exist only for individually fetched playlists (`PlaylistItemsSyncTracker`).
On online refresh, if the query contains any playlist rule, sync all unsynced non-smart
playlists first (same filter idiom as `PlaylistSyncWorker.swift:166`). Offline, evaluate anyway
but surface "playlist data may be incomplete" when the tracker reports unsynced playlists.

### Offline refresh

If offline: skip both sync steps, evaluate against the local cache, persist result, and mark
the result as generated offline (show in UI next to refreshed-at).

## Rule model (V1)

`SmartPlaylistQuery` — Codable, AND-combined list of rules:

1. `addedWithinDays(Int)` — `addedDate >= cutoff`. Songs with `addedDate == nil` are excluded;
   count them and surface "N songs have no added-date yet" in the results footer when > 0.
2. `played(PlayedRule)` — `.never` (`playCount == 0`), `.notInLastDays(Int)`
   (`lastPlayedDate == nil OR lastPlayedDate < cutoff`), `.inLastDays(Int)`.
3. `playlistCount(comparison: .fewerThan | .moreThan, count: Int)` — SUBQUERY count of user
   playlists containing the song, modeled on `RecentTracksQuery.songNotInAnyUserPlaylist`
   (scope `$item.playlist.account`, exclude `smart_` ids and nil-name playlists).
4. `notInPlaylist(playlistId: String, name: String)` — SUBQUERY count for that playlist == 0.
5. `inPlaylist(playlistId: String, name: String)` — SUBQUERY count for that playlist > 0.

Always AND in `SongMO.excludeServerDeleteUncachedSongsFetchPredicate` and account scoping.
Result ordering: `addedDate` desc (nil last), then title. Evaluation = single CoreData fetch
with compound predicate; no per-song loops.

Store playlist display names inside playlist rules so the builder/summary can render offline;
resolve by id at evaluation time (if the playlist vanished, drop the rule at evaluation and
flag it in the UI).

## Persistence

`SmartPlaylistStore` (AmperfyKit), UserDefaults, keys `amperfy.fork.smartPlaylists.*`,
injected `UserDefaults` for tests, `GigsSettings`-style Codable blob:

```swift
struct SmartPlaylistState: Codable {
  var query: SmartPlaylistQuery
  var frozenSongIds: [String]     // canonical song ids, ordered
  var refreshedAt: Date
  var wasOfflineRefresh: Bool
  var songsMissingAddedDate: Int  // for footer note
}
```

Single "current" state in V1, but store API takes/returns whole state objects so a keyed list
is a trivial V2 extension. Rehydrate via one `id IN %@` fetch, re-sort by the stored id array;
missing ids (deleted songs) are dropped silently.

## New files

AmperfyKit (all public where needed; each new file needs the 4 pbxproj entries —
follow `RecentTracksQuery.swift` as the model, correct target membership):

- `AmperfyKit/SmartPlaylists/SmartPlaylistQuery.swift` — rule model, Codable, summary text
- `AmperfyKit/SmartPlaylists/SmartPlaylistQueryEngine.swift` — predicate build + evaluate
- `AmperfyKit/SmartPlaylists/SmartPlaylistStore.swift` — persistence
- `AmperfyKit/SmartPlaylists/SmartPlaylistRefresher.swift` — backfill orchestration + evaluate + persist

App target:

- `Amperfy/Screens/ViewController/SmartPlaylists/SmartPlaylistDetailVC.swift` — results screen
- `Amperfy/Screens/ViewController/SmartPlaylists/SmartPlaylistBuilderVC.swift` — rule builder

Tests (AmperfyKitTests target, in-memory CoreData via `CoreDataHelper`/`CoreDataSeeder`):

- `SmartPlaylistQueryEngineTest` — each rule type + combinations + exclusion predicate
- `SmartPlaylistStoreTest` — round-trip via injected UserDefaults suite
- `LibraryDisplaySettingsSmartPlaylistsMigrationTest` — copy Gigs migration test
- Parser test additions for playCount/played merge + fractional-seconds fallback

## Library tab entry (4-part Gigs precedent — all four required)

1. `LibraryDisplayType.smartPlaylists = 17` + `displayName` ("Smart Playlists") +
   add to `defaultSettings.inUse` (`LibraryDisplaySettings.swift`)
2. Icon + destination in `LibraryDisplayType+Extension.swift` (SF symbol e.g. `gearshape.2`
   or `sparkles` — pick something distinct from existing rows)
3. Factory in `AppStoryboard.swift` (code-instantiated VC, one-liner like `segueToGigs`)
4. Migration: `LibrarySyncVersion.v23 = 17`, bump `newestVersion`, copy the Gigs block in
   `LibraryUpdater.swift:236-263` (guard: absent from BOTH lists)

Check `CarPlayLibraryTabExtension.swift` tolerates the new case (exclude it from CarPlay for V1).

## Results screen (SmartPlaylistDetailVC)

Skeleton: copy `RecentTracksDetailVC` (`MultiSourceTableViewController`, `PlayableTableCell`,
`containableAtIndexPathCallback` / `playContextAtIndexPathCallback` / `swipeCallback`,
mini-player safe area, `UIContentUnavailableConfiguration.empty()` empty state).

- Table header view: artwork preview (first result's artwork; placeholder when empty),
  query summary line, "Refreshed <relative time>" (+ "offline" tag when applicable),
  **Refresh button directly under the artwork**, Play + Shuffle buttons,
  Edit Query button (opens builder), footer note for songs-missing-addedDate / unsynced playlists.
- NO auto-refresh anywhere: load frozen ids on appear; never re-evaluate without the button.
- Refresh button: spinner while running (backfill can take a few seconds), disabled during run.
- Playback: `PlayContext(name: "Smart Playlist", index:, playables:)` with id-stable resolution
  (copy `RecentTracksPlaybackResolver` approach — refresh swaps the array, so resolve by song id).
- Navigation: Library row pushes SmartPlaylistDetailVC. If the store is empty (first use),
  immediately present the builder modally over the empty state.

## Builder screen (SmartPlaylistBuilderVC)

Modal nav-wrapped table form ("Match ALL of the following"):
- One row per active rule: label + value; tap edits (UIMenu / stepper / picker as fits).
  Playlist pickers list non-smart named playlists for the account.
- "+ Add rule" row → menu of the rule types not yet sensible to duplicate
  (allow multiple notInPlaylist/inPlaylist rules; single instance of the others).
- Swipe-to-delete rules. "Run Query" primary button → dismiss, run refresh flow, show results.
- Cancel keeps prior state untouched. Editing an existing query pre-populates rows.

## Side quest — Delete Playlist in PlaylistDetailVC ⋯ menu

Copy `PlaylistFolderContentsVC.confirmDeletePlaylist/deletePlaylist` (:396-428) exactly:
confirmation alert, capture id+account BEFORE delete, `library.deletePlaylist`, `saveContext()`,
then async `syncUpload(playlistIdToDelete:)` with eventLogger error reporting (without the
upload the next sync resurrects the playlist). Append as trailing destructive inline UIMenu
in the lazyMenu closure (`PlaylistDetailVC.swift:161-199`), `attributes: .destructive`,
`.trash` image. Gate on `isOnlineMode` and `!playlist.isSmartPlaylist` (same as Edit at :176).
After successful local delete: **pop the VC** immediately (the FRC is bound to the deleted MO).

## Conventions / guardrails

- Verbose variable names, no single letters. Match surrounding code style; run SwiftFormat
  (`.swiftformat` at root) on new files.
- No CoreData model changes in V1.
- Do not touch `smart_` id semantics (Ampache server-side smart playlists).
- Tests must pass via `scripts/test.sh`.
- Do NOT run git commit/stage — the session orchestrator handles commits.
- Update module README if one exists for touched areas; add
  `AmperfyKit/SmartPlaylists/README.md` (brief architecture note).
