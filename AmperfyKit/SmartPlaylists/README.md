# SmartPlaylists (AmperfyKit)

On-device smart playlist engine — the query model, its Core Data evaluation, the
frozen-result persistence, and the refresh orchestration. UI lives in the app
target (`Amperfy/Screens/ViewController/SmartPlaylists/`); nothing here imports
UIKit.

## Architecture

A smart playlist is an AND-combined list of rules that is evaluated **only when
the user explicitly refreshes**. The result is then FROZEN: an ordered list of
song ids in UserDefaults that survives launches and never re-evaluates itself.
This is a deliberate product decision — the list is a stable working set the
user triages against, not a live view.

```
SmartPlaylistQuery  ──►  SmartPlaylistQueryEngine  ──►  SmartPlaylistEvaluation
   (rules, Codable)         (one compound fetch)          (songs + caveats)
            ▲                                                     │
            │                                                     ▼
     SmartPlaylistRefresher ──── backfill / drain ────►   SmartPlaylistStore
       (orchestration)                                  (frozen ids, UserDefaults)
```

## Components

| File | Purpose |
| --- | --- |
| `SmartPlaylistQuery.swift` | The rule model (`SmartPlaylistRule`, `SmartPlaylistPlayedRule`, `SmartPlaylistCountComparison`), Codable, plus display/summary text and the builder's "can this rule repeat?" policy. |
| `SmartPlaylistQueryEngine.swift` | Rule → `NSPredicate` translation and `evaluate(...)`: one fetch for the result set, one cheap `count` fetch for the missing-added-date footer. |
| `SmartPlaylistStore.swift` | `SmartPlaylistState` (query + frozen ids + provenance) persisted as a Codable blob under `amperfy.fork.smartPlaylists.*`, plus id → `SongMO` rehydration. |
| `SmartPlaylistRefresher.swift` | The single path that regenerates a result: newest-albums backfill → unsynced-playlist drain → evaluate → persist. |

## Working patterns

* **No Core Data schema changes.** Play data is merged into the existing
  `playCount` / `lastPlayedDate` fields by `SsSongParserDelegate`
  (`max` / `later` of local and server), so offline plays stay visible instantly
  and a later sync can only raise the floor. Persistence is UserDefaults, in the
  established `GigsSettings` / `PlaylistItemsSyncTracker` style.
* **One fetch, no loops.** Playlist-*membership* rules (`inPlaylist` /
  `notInPlaylist`) are `SUBQUERY` counts over the song's inverse `playlistItems`
  relationship, scoped through `$item.playlist.account` — the same idiom as
  `RecentTracksQuery.songNotInAnyUserPlaylist`. Every fetch also ANDs in
  `SongMO.excludeServerDeleteUncachedSongsFetchPredicate` and account scoping.
* **`playlistCount` counts DISTINCT playlists, in Swift.** A song can be listed
  twice in one playlist, and `SUBQUERY(...).@count` counts entries — it reported
  such a song as sitting in two playlists (QA 2026-08-17). Core Data has no
  distinct aggregate that survives translation to the SQLite store, so
  `evaluate` drops that rule from the predicate and applies
  `distinctUserPlaylistCountsBySongId` — one `PlaylistItemMO` fetch folded into
  a `songId → distinct playlist count` map — to the fetched songs (and to the
  missing-added-date count, which runs the same rules). Membership rules are
  unaffected by duplicates and stay predicates.
* **`addedDate` is sparse.** Only song-level XML populates it, so an online
  refresh with an `addedWithinDays` rule first pages `getAlbumList2 type=newest`
  and syncs each album's songs, stopping at the first page entirely outside the
  window (hard caps: 500 albums / 10 pages of 50).
* **Playlist rules need item-synced playlists.** `PlaylistItemMO` rows exist
  only for individually fetched playlists, so an online refresh drains the
  `PlaylistItemsSyncTracker` unsynced set first. Offline it evaluates anyway and
  reports `hasIncompletePlaylistData`.
* **Honest caveats over silent wrongness.** Songs with no `addedDate` are
  excluded but counted; playlist rules whose playlist vanished are dropped and
  reported rather than matching nothing forever.

## UI (app target)

`Amperfy/Screens/ViewController/SmartPlaylists/` consumes this module. Reached
from the Library tab's "Smart Playlists" row (`LibraryDisplayType.smartPlaylists`,
rawValue 17; upgrading users get it injected by the `LibrarySyncVersion.v23`
block in `LibraryUpdater`). Excluded from CarPlay in V1.

| File | Purpose |
| --- | --- |
| `SmartPlaylistDetailVC.swift` | The frozen results list. Loads via `SmartPlaylistStore.loadCurrentState()` + `resolveSongs`; the ONLY thing that ever calls `SmartPlaylistRefresher.refresh` is the header's Refresh button (and Run Query in the builder). |
| `SmartPlaylistDetailHeaderView.swift` | Artwork preview → **Refresh button directly beneath it** → query summary → "Refreshed just now / <relative> · N songs · Offline" → Play / Shuffle → Edit Query → caveat footer. |

Empty states are **rows, never `contentUnavailableConfiguration`** (see
`EmptyStateRow` in `SmartPlaylistDetailVC`). A `UITableViewController` whose
table has zero rows publishes only "Empty list" to accessibility and stops
vending its table header view — Refresh / Play / Shuffle / Edit Query dropped
out of the VoiceOver tree while staying tappable, and the overlay additionally
silenced the navigation bar and drew over the header. First use shows a tappable
"No Smart Playlist Yet" row (header detached); a stored query that matched
nothing keeps the header and shows a "No songs match this query" row.
| `SmartPlaylistBuilderVC.swift` | Modal "Match ALL of the following" rule form. Edits a copy; Cancel leaves the stored state untouched. |
| `SmartPlaylistRuleMenuBuilder.swift` | The `UIMenu`s behind the rule rows (day/count presets plus a "Custom…" alert escape hatch) and the "+ Add Rule" menu, gated by `canAddRule(ofKind:)`. |
| `SmartPlaylistPlaylistPickerVC.swift` | Playlist chooser for the membership rules — non-system, non-smart, named playlists for the account. |

## V2 hooks

`SmartPlaylistStore` takes and returns whole `SmartPlaylistState` values even
though V1 stores exactly one, so a keyed list (saved smart playlists, favourites,
Home mixing, export-to-regular-playlist) is an additive change here rather than a
call-site rewrite.

## Tests

`AmperfyKitTests/Cases/SmartPlaylists/` — engine rules and combinations against
an in-memory store, store round-trips against an injected `UserDefaults` suite,
and the parser's play-data merge / tolerant date parsing.
