# SmartPlaylists (AmperfyKit)

On-device smart playlist engine — the query model, its Core Data evaluation, the
frozen-result persistence, and the refresh orchestration. UI lives in the app
target (`Amperfy/Screens/ViewController/SmartPlaylists/`); nothing here imports
UIKit.

## Architecture

A smart playlist is a boolean query over the library that is evaluated **only
when the user explicitly refreshes**. The result is then FROZEN: an ordered list
of song ids in UserDefaults that survives launches and never re-evaluates
itself. This is a deliberate product decision — the list is a stable working set
the user triages against, not a live view.

```
SmartPlaylistQuery  ──►  SmartPlaylistQueryEngine  ──►  SmartPlaylistEvaluation
  (AND/OR tree,            (2 fetches +                   (songs + caveats)
   Codable)                 SmartPlaylistTreeEvaluator)
            ▲                                                     │
            │                                                     ▼
     SmartPlaylistRefresher ──── backfill / drain ────►   SmartPlaylistStore
       (orchestration)                                  (frozen ids, UserDefaults)
```

## The query model (V1.5)

A query is a **top-level container of items**; each item is either a bare rule
or a **group** of rules. Groups never contain groups — one nesting level is the
whole model. Every container (top level and each group) carries a single
`SmartPlaylistCombinator`, `.all` (AND) or `.any` (OR), so a level is always
uniform; mixing is expressed by nesting a group. `.all` is the default
everywhere, which is exactly V1 behaviour.

```swift
SmartPlaylistQuery(items: [
  .rule(.addedWithinDays(30)),
  .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
    .played(.never),
    .playlistCount(comparison: .fewerThan, count: 2),
  ])),
])
// summaryText:
// "Added in the last 30 days and (Never played or In fewer than 2 playlists)"
```

**Codable migration.** V1 (build 83) persisted a flat `{"rules": [...]}` with an
implicit AND. `SmartPlaylistQuery.init(from:)` decodes that shape into a
top-level `.all` container of bare rules, so shipped users' stored queries and
frozen results survive the upgrade untouched. The new shape is
`{"combinator": ..., "items": [...]}`, written on the next save.
`SmartPlaylistStoreTest` holds a captured raw V1 blob as the regression proof —
rule cases may be *added* (that is how `completeAlbum` shipped), but an existing
case's name or associated-value labels can never change without a migration.

## Components

| File | Purpose |
| --- | --- |
| `SmartPlaylistRule.swift` | The leaf model (`SmartPlaylistRule`, `SmartPlaylistPlayedRule`, `SmartPlaylistCountComparison`), its `Kind` identity and per-container repeatability policy, and each rule's display text. |
| `SmartPlaylistQuery.swift` | The container model (`SmartPlaylistCombinator`, `SmartPlaylistRuleGroup`, `SmartPlaylistQueryItem`, `SmartPlaylistQuery`), the V1 → V1.5 Codable migration, and `summaryText`. |
| `SmartPlaylistQueryEngine.swift` | `evaluate(...)`: rule pruning, the candidate fetch, the playlist-facts fetch, and the two-pass loop that produces the results and `songsMissingAddedDate`. |
| `SmartPlaylistTreeEvaluator.swift` | The per-song boolean-tree walk and every leaf check, including the Swift mirror of `WholeAlbumPredicates`. |
| `SmartPlaylistStore.swift` | `SmartPlaylistState` (query + frozen ids + provenance) persisted as a Codable blob under `amperfy.fork.smartPlaylists.*`, plus id → `SongMO` rehydration. |
| `SmartPlaylistRefresher.swift` | The single path that regenerates a result: album track-count refresh → recent-songs backfill → unsynced-playlist drain → evaluate → persist. |

## Working patterns

* **No Core Data schema changes.** Play data is merged into the existing
  `playCount` / `lastPlayedDate` fields by `SsSongParserDelegate`
  (`max` / `later` of local and server), so offline plays stay visible instantly
  and a later sync can only raise the floor. Persistence is UserDefaults, in the
  established `GigsSettings` / `PlaylistItemsSyncTracker` style.
* **Two fetches, then Swift.** V1 ANDed one `NSPredicate` per rule into a single
  fetch. OR makes that impossible — an OR branch cannot be ANDed in — so
  evaluation now runs (1) one candidate fetch carrying only the always-on guards
  (`SongMO.excludeServerDeleteUncachedSongsFetchPredicate` + account scoping),
  already sorted into presentation order; (2) one `PlaylistItemMO` fetch, only
  when a playlist rule is active, folded into both the distinct-playlist-count
  map and the member-id sets of the playlists the query names; then (3) one
  in-Swift tree walk per song. Per-song work is field reads and hash lookups, so
  ~11k songs stay cheap. The `album` relationship is prefetched only when a
  `completeAlbum` rule will read it.
* **`playlistCount` counts DISTINCT playlists.** A song can be listed twice in
  one playlist, and `SUBQUERY(...).@count` counts entries — it reported such a
  song as sitting in two playlists (QA 2026-08-17). Core Data has no distinct
  aggregate that survives translation to the SQLite store, hence the folded map.
* **`completeAlbum` mirrors `WholeAlbumPredicates` exactly** with
  `minSongCount = 3`: a `releaseType` containing `"single"` vetoes; otherwise the
  verdict is `remoteSongCount >= 3` alone, so nil metadata is classified purely
  by count. A song with no album is NOT part of a complete album — the one thing
  the Core Data predicate could only imply through NULL propagation, stated
  explicitly in `SmartPlaylistTreeEvaluator.isPartOfCompleteAlbum`.
* **`songsMissingAddedDate` is tree-aware.** It counts songs that would match if
  every `addedWithinDays` rule were treated as satisfied but do not match as
  things stand — i.e. songs kept out *solely* by an unknown added-date. A
  nil-date song that still qualifies through an OR branch is in the results and
  is not counted, which a naive "count the nil dates" pass would get wrong.
* **Vanished playlists loosen, never empty.** A rule naming a deleted playlist is
  pruned from its container and reported in `droppedPlaylistRules`; a group left
  with no rules is removed from the top level, because an empty OR group would
  otherwise blank the whole result.
* **Playlist rules need item-synced playlists.** `PlaylistItemMO` rows exist
  only for individually fetched playlists, so an online refresh drains the
  `PlaylistItemsSyncTracker` unsynced set first. Offline it evaluates anyway and
  reports `hasIncompletePlaylistData`.
* **Honest caveats over silent wrongness.** Songs with no `addedDate` are
  excluded but counted; playlist rules whose playlist vanished are dropped and
  reported rather than matching nothing forever.

## Backfill — why it works the way it does

`addedDate` is populated **only** by song-level XML; the bulk album sync never
sets it (`ADDED_DATE_INVESTIGATION.md`). So an online refresh whose query has an
`addedWithinDays` rule must first make song-level dates exist for anything the
window could match.

### Which server primitive we use, and why

V1 walked `getAlbumList2 type=newest` and stopped at the first page with nothing
inside the window. That ordering keys on the **album's** created date, so an old
album that GAINED new songs is structurally invisible to it — the real case was
album "Joshua" (created 2026-03-22) whose songs arrived 2026-07-10, hundreds of
albums past the stop point.

We investigated our Navidrome fork's Subsonic surface (2026-08-17) for a
song-level recency primitive to replace the walk with. There isn't one:

* **`search3` takes no sort parameter** (`server/subsonic/searching.go:32-43`
  is the complete param list). An empty query is ordered by
  `media_file.rowid ASC` — hardcoded, ascending, with no descending option
  (`persistence/sql_search.go:59-61`, `persistence/mediafile_repository.go:436`),
  so the newest songs sit at the *tail* of an unbounded result set and search3
  returns no total count to seek to.
* **`getAlbumList2` has no song-level twin.** Its types are all album-level
  (`server/subsonic/album_lists.go:27-63`); `type=recent` is recently *played*,
  not recently added. The song endpoints that exist sort by random
  (`getRandomSongs`, no offset at all), name (`getSongsByGenre`) or `starred_at`
  (`getStarred2`).
* **The fork adds nothing here** — `git diff origin/master...HEAD` touches no
  file under `server/subsonic/`.
* Navidrome *does* know how to sort songs by created — `"recently_added"` maps
  to `media_file.created_at` in `persistence/mediafile_repository.go:89-90` —
  but it is reachable only through the **native REST API** (`GET /api/song?
  _sort=recently_added`), which needs Navidrome's JWT auth rather than Subsonic
  salt/token auth.

So we take the addendum's sanctioned fallback — sync candidate albums' songs,
then let SONG dates decide — behind a step that first makes the local library's
idea of each album's size current. Three steps, in this order:

0. **Album track-count refresh** — pages the FULL album listing
   (`syncAlbumListPage`: `getAlbumList2 type=alphabeticalByName` on Subsonic,
   `albums` on Ampache — the same request the initial library sync pages
   through) so every album's `remoteSongCount` is what the server says *now*.
   Caps: `albumTrackCountPageSize = 500` (the Subsonic maximum for
   `getAlbumList2 size`, and the initial sync's page size) and
   `maxAlbumTrackCountPages = 24` → 12,000 albums. The cap was raised from 8
   pages after live QA against a 7,746-album library showed the alphabetical
   listing truncating at 4,000 — late-alphabet albums kept the stale-count bug.
1. **Newest-albums walk** — genuinely new albums. Pages `getAlbumList2
   type=newest`, syncs songs for albums that need them, and stops at the first
   page whose albums hold no SONG inside the window. Caps:
   `maxBackfillAlbums = 500`, `maxBackfillPages = 10`, `backfillPageSize = 50`,
   the album budget it shares with step 2.
2. **Gained-songs scan** — the "Joshua" pass. Albums where
   `remoteSongCount > (songs we hold)` gained tracks; albums holding
   `nil`-added-date songs (synced before the fractional-seconds parsing fix)
   follow at lower priority. Finding them costs no further network calls,
   because step 0 has already brought the counts it reads up to date.

The skip-already-synced optimisation is kept, and `needsSongSync` also refetches
when the server says an album holds more songs than we do — without that, pass 1
would have skipped "Joshua" even had it reached it.

### Why step 0 is not optional (live QA, 2026-08-17)

Pass 2's comparison is only as good as `remoteSongCount`, and that field is
written **only** when an album listing containing that album is parsed. Nothing
in a refresh, a relaunch or a background sync re-reads it for an arbitrary
album: `type=newest` is ordered by the ALBUM's created date, which does not move
when the album gains a track, and the newest walk stops at the query window
anyway. So an old album that gains a song server-side keeps whatever count some
past listing left behind — for good.

The QA fixture that proved it: local `remoteSongCount` 3, server `songCount` 4,
the fourth song added that day. Pass 2's candidate set was empty, "Added in the
last 7 days" returned 0 songs, and no amount of refreshing or relaunching
changed it — the song became visible only if the user happened to browse that
album. Step 0 is what turns that album into a candidate.

**Cost.** Only on an online refresh whose query has an `addedWithinDays` rule,
and at most once per refresh. For the workshop's production library (~11k songs,
~1k albums) that is **3 requests** — 500 + 500 + a short page — of light
album-level metadata, no song XML. The loop stops at the first short page, so
the 24-page worst case (12,000 albums) is only paid by libraries that actually
hold that many; a library past the cap keeps the old behaviour for its
late-alphabet tail. Offline the step is skipped along with the rest of the sync work and
the refresh evaluates whatever is local. A refresh is an explicit,
spinner-blocking user action, with its own progress phase
(`refreshingAlbumTrackCounts` → "Checking album track counts (N)…"), which is
what makes paying the cost there the right trade rather than on every launch.

The alternatives were worse, not cheaper: re-paging `getAlbumList2 type=newest`
across the library needs no new API call but writes `updateIsNewestInfo` for
every album, turning the app's "Newest" section into the whole library; and
`sync(album:)` per album is one song-level request each — three orders of
magnitude more expensive than one 500-album listing page.

### Known limit

On a **fresh install** nothing has been song-synced yet, so no album can look
"short" and pass 2 finds nothing; first-refresh coverage is whatever pass 1's
caps allow. Step 0 does not change that — it makes counts current, but an album
we hold no songs for is deliberately not a pass-2 candidate. Closing the gap
properly needs a song-level recency endpoint on the server — a
`filter.SongsByRecentlyAdded()` plus a `getNewestSongs` handler (or a
`sort=recentlyAdded` param on `search3`) mirroring `getSongsByGenre`. The
persistence-layer sort mapping already exists, so it is a small fork addition.
Note also that Subsonic's `created` attribute on a song is `mf.BirthTime` (file
ctime), **not** `media_file.created_at` (`server/subsonic/helpers.go:219`) — any
such endpoint should reconcile the two.

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

| File | Purpose |
| --- | --- |
| `SmartPlaylistBuilderVC.swift` | The modal query form. Edits a copy; Cancel leaves the stored state untouched; Run Query calls `removeEmptyGroups()` first. |
| `SmartPlaylistBuilderRowLayout.swift` | Pure query → sections/rows mapping (`SmartPlaylistBuilderRow`, `SmartPlaylistBuilderRuleLocation`, section headers). No UIKit. |
| `SmartPlaylistQuery+BuilderEditing.swift` | Every tree edit the builder makes, plus `SmartPlaylistRule.Kind.defaultRule`. |
| `SmartPlaylistBuilderCells.swift` | `SmartPlaylistBuilderStyle` (group indent + card fill), the rule/add-rule row, the group header row, the trailing actions row. |
| `SmartPlaylistConnectorChip.swift` | The and/or chip: the pill button plus its section-header and cell wrappers. |
| `SmartPlaylistRuleMenuBuilder.swift` | The `UIMenu`s: rule value menus (day/count presets plus a "Custom…" alert escape hatch), the per-container "+ Add rule" menu, the "+ Add group" first-rule menu, and the group ⋯ menu. |
| `SmartPlaylistPlaylistPickerVC.swift` | Playlist chooser for the membership rules — non-system, non-smart, named playlists for the account. |

### The builder's shape (V1.5)

Each top-level item is its own inset card. **Connector chips** sit between
adjacent items — as section headers at the top level (the only space between two
cards), as ordinary rows inside a group card. A level is uniform by
construction, so every chip at a level renders the same word and tapping any one
flips the whole level; mixing is what groups are for. Groups are cards with a
tinted fill, an indent, a "Group — match all/any" header row carrying the ⋯ menu
(combinator + Delete Group), their own chips and their own "+ Add rule" row.
"+ Add group" asks for the group's FIRST RULE and creates the group around the
answer, so dismissing the menu leaves nothing behind; `removeEmptyGroups()` on
Run covers a group emptied by deleting its rules.

Two things are load-bearing:

* **Never assign `SmartPlaylistQuery.rules`.** Its setter flattens the tree into
  bare top-level rules and destroys every group. The builder goes through
  `SmartPlaylistQuery+BuilderEditing`, which only ever touches `items`.
* **Rows, not decorations.** Chips, group headers and add-rule affordances are
  real rows or real section headers, each vending its own accessibility element
  (containers set `isAccessibilityElement = false` + explicit
  `accessibilityElements`) — the same lesson as the empty-state bug above. Chips
  are labelled by intent ("Change to any" / value "Currently all"), because
  "and" and "or" are nearly indistinguishable by ear.

## V2 hooks

`SmartPlaylistStore` takes and returns whole `SmartPlaylistState` values even
though V1 stores exactly one, so a keyed list (saved smart playlists, favourites,
Home mixing, export-to-regular-playlist) is an additive change here rather than a
call-site rewrite.

## Tests

`AmperfyKitTests/Cases/SmartPlaylists/`, all against an in-memory Core Data
store:

| Suite | Covers |
| --- | --- |
| `SmartPlaylistQueryEngineTest` | Every rule kind, the always-on guards, ordering, AND/OR trees (group-of-one, empty top level, two intersected OR groups), the `completeAlbum` truth table, and the tree-aware `songsMissingAddedDate`. |
| `SmartPlaylistStoreTest` | Round-trips through an injected `UserDefaults` suite, `summaryText` rendering, per-container repeatability — and the **captured raw V1 blob** that proves build-83 state still decodes. |
| `SmartPlaylistRefresherTest` | The backfill's candidate choice, via a recording `LibrarySyncer`: the "Joshua" album is fetched, settled albums are not, the backfill is skipped without an `addedWithinDays` rule, and offline does no syncing. Plus the track-count refresh — a stale count is relearned and the album is then song-synced, the page cap holds against an endless listing, a short page ends the paging, and offline/no-rule refreshes never request a page. |
| `SsSongPlayDataParserTest` | The parser's play-data merge and tolerant date parsing. |
