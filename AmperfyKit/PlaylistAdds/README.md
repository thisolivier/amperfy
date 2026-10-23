# PlaylistAdds (AmperfyKit)

The durable queue behind "add this song to that playlist" (AMP-28). Owns the
record of adds the server has not confirmed, the worker that drains it, and the
guard that stops a server-wins fetch from erasing an add that is still in
flight. No UIKit — presentation lives in the app target
(`Amperfy/LoudFailureAlertPresenter.swift`,
`Amperfy/AppDelegatePlaylistAddExtensions.swift`).

## The bug this module exists to kill

An add was a fire-and-forget `Task` on a view controller: the songs appeared
locally at once, the upload went out unawaited, and three separate paths turned
a failure into silence.

1. `syncUpload(playlistToAddSongs:)` opened with
   `guard isSyncAllowed, !songs.isEmpty else { return }` — so **offline
   returned the same answer as success**. The caller carried on, the songs
   stayed appended locally, and nothing remembered the server had never been
   told.
2. A real refusal (the Navidrome fork answers Subsonic error 50 for a playlist
   it considers server-owned, 70 for one it no longer has) surfaced as an
   `EventLogger` banner — which any presented view controller suppresses
   (AMP-6), and the "Add to Playlist" picker *is* a sheet.
3. The next per-playlist `syncDown` is server-wins and positional:
   `SsPlaylistSongsParserDelegate` rewrites `Playlist.items` from the response
   envelope and deletes whatever the server did not mention. The local-only
   songs were exactly that, so they were truncated away.

Net effect: songs the user had watched appear in a playlist silently vanished
some minutes later, with no error anywhere.

## Architecture

Local-first, then prove it. Every add writes a Core Data row in the **same save**
as the optimistic local append, so the intent is durable before a network call
exists at all.

```
      Route 1                       Route 2
 PlaylistSelectorVC         AddToPlaylistManager+Adding
 (swipe / menu / player)    (in-playlist edit → "+" picker)
         │                            │
         └──────────┬─────────────────┘
                    ▼
        playlist.append(playables:)            ← visible immediately
        store.enqueue(songs:to:account:)       ← durable, same save
                    │
                    ▼
          PlaylistAddUploadService  ──────►  LibrarySyncer.syncUpload
                    │                        (one request per playlist)
     ┌──────────────┼───────────────────┐
     ▼              ▼                   ▼
  landed       refused (50/70)      transient
  clear rows   clear rows           keep rows, attempts += 1
  syncDown     roll back append     banner once per pass
               LOUD modal alert     retry on scene foreground
                    │
                    ▼
   PendingPlaylistSongAddReconciler.reapplyPendingAdds
   (after EVERY syncDown(playlist:), via LibrarySyncerProxy)
```

### Three outcomes and no fourth

| Outcome | Rows | Local items | User sees |
| --- | --- | --- | --- |
| Landed | deleted | reconciled by a follow-up `syncDown` | nothing (it worked) |
| Permanently refused (Subsonic 50 / 70) | deleted | **rolled back** | modal alert |
| Transient (offline, timeout, 5xx, bad body) | kept, attempt counted | left in place | one banner per pass |

Offline is none of the three: no request is made, no row is touched, no attempt
is counted, and `PlaylistAddFlushSummary.wasSkippedOffline` says so. It is never
reported as success.

There is deliberately **no attempt ceiling and no backoff**. The retry rate is
already bounded by what triggers a flush (an add, and the app coming to the
foreground), and a song the user put in a playlist is not something to give up
on. Same rule as `PlaylistFolderStore+PendingCreation`.

## Components

| File | Purpose |
| --- | --- |
| `PendingPlaylistSongAddStore.swift` | The queue. Enqueue (saves immediately), read grouped into one batch per playlist, resolve (delete) or record a transient failure. Sweeps orphaned rows — a row whose playlist or song no longer exists locally can never be uploaded, so it is dropped rather than retried forever. |
| `PlaylistAddUploadService.swift` | One drain pass per call, one request per playlist. Classifies the outcome, rolls back on a permanent refusal, reports failures through two injected closures so AmperfyKit never touches UIKit. Guards against overlapping passes. |
| `PlaylistAddUploadOutcome.swift` | The value types crossing the boundary: `PlaylistAddPermanentFailure` (what the modal needs to say), `PlaylistAddFlushSummary` (what a pass actually did — so the >100-songs confirmation can report a real result instead of asserting success before the request was made), and `PlaylistAddUploadError.offline`. |
| `PendingPlaylistSongAddReconciler.swift` | Re-appends queued songs that a per-playlist fetch truncated. Hooked into `LibrarySyncerProxy.syncDown(playlist:)` with `defer`, which is the single choke point every caller — including `Playlist.fetchFromServer` — routes through. Also hooked into `syncUpload(playlistToUpdateName:)` — see below. |

### Two places the rewrite can bite, not one

`syncDown(playlist:)` is the obvious one. The other is
`syncUpload(playlistToUpdateName:)`, which does not look like a fetch at all:
for a playlist with no server id yet it goes through `validatePlaylistId` →
`createPlaylistRemote`, which parses the **create** response with
`SsPlaylistSongsParserDelegate`. That response describes a brand-new, *empty*
playlist, so the delegate's "delete every local item past the end of the
server's list" branch deletes the lot. Creating a playlist with songs in it
wiped them locally while the upload went on to put them on the server — the new
playlist read 0 songs until its detail screen was opened.

Both methods therefore carry the guard. This is also why a pending row points at
the playlist **object** and not its id: the row has to be enqueued *before* the
create (so the user sees the right count immediately) and still resolve to the
right playlist after the server assigns it an id.

Supporting pieces outside this directory:

- `Storage/ManagedObjects/PendingPlaylistSongAddMO+*.swift` and
  `Storage/EntityWrappers/PendingPlaylistSongAdd.swift` — the row. Model
  version **v54** (additive; the mapping is inferred, and
  `PendingPlaylistSongAddMigrationTest` proves the v53 → v54 step runs, because
  `CoreDataMigrator` answers a failed step with `fatalError`).
- `LibraryStorage` — create / delete / fetch, account-scoped like `PlaylistMO`.
  The entity is also listed in `entitiesToDelete`: `clearStorage` uses
  `NSBatchDeleteRequest`, which bypasses the Playlist cascade.
- `LibraryStorage.saveContext()` — assigns **permanent object IDs before
  saving**. Not strictly part of this module, but it is what makes a local-first
  add actually *render*: see below.

## Why `saveContext` obtains permanent IDs first

An add that is invisible is not an add. Every list screen is an
`NSFetchedResultsController` feeding a
`UITableViewDiffableDataSource<Int, NSManagedObjectID>` — the snapshot's item
identity *is* the object ID, and each cell provider resolves it back with
`context.existingObject(with:)`.

Core Data assigns permanent IDs during `save()`, but `save()` opens by calling
`processPendingChanges`, which posts `objectsDidChange` — exactly the
notification the FRC reacts to. So the FRC was handed new rows while their IDs
were still **temporary**, published a snapshot keyed on them, and a moment later
Core Data swapped those IDs for permanent ones. Every new row's identity was
then dead, `existingObject(with:)` threw, and all twelve snapshot-backed cell
providers fell back to a bare `UITableViewCell()` — a row with separators and no
title, artist or artwork. It healed only on navigating away, because a fresh
fetch produced permanent IDs.

`obtainPermanentIDs` before the save closes that window. It is one fix for the
whole symptom family: blank rows after an add, list counts a step behind, a
header stuck on a pre-rollback count. `PlaylistItemCellResolver` (app target) is
the belt to that braces — it resolves by *position* when an identity fails, so a
future regression degrades to a correct row rather than an empty one.

### Rows and headers refresh by different routes

The rows are driven by the FRC, the header is not. `SingleSnapshotFetchedResults`
`TableViewController` calls `snapshotDidChange?()` after applying each snapshot,
and a screen with a `GenericDetailTableHeader` has to opt in by assigning
`snapshotDidChange = detailOperationsView?.refresh`. `PlaylistDetailVC` did;
`PlaylistEditVC` did not, so its header only updated from gesture-driven call
sites on that screen. A rollback is the one item change on the edit screen the
user did *not* initiate there, so the rows dropped to 4 while the header kept
reading "6 Songs · 22m" until `endEditing()` (whose `defer { refresh() }`
explains the heal-on-exit). Both screens now assign the hook.

Still unassigned, and out of AMP-28's scope because nothing mutates their
contents behind the user's back: `AlbumDetailVC`, `ArtistDetailVC`,
`GenreDetailVC`, `PodcastDetailVC`.

## Working patterns

- **The row holds relationships, not id strings.** A freshly created playlist
  has an *empty* server id until its create request round-trips, and this fork
  has already lived through a server-wide track-id switchover (build 97) — an id
  captured at enqueue time could name nothing. Object identity survives both.
- **Resolve rows before the reconciling fetch.** The follow-up `syncDown` runs
  through the reconciliation guard; with the rows already deleted, the guard
  correctly leaves the server's copy alone instead of re-appending it.
- **Reconciliation is presence, not multiplicity.** A queued song already
  present once is left alone, so a deliberate duplicate add racing a fetch can
  come back as one copy instead of two. Appending every queued row
  unconditionally would instead double every add that had in fact succeeded —
  strictly worse.
- **Failures leave AmperfyKit as values.** The app layer decides that a
  permanent refusal is a modal (walking the `presentedViewController` chain, so
  the sheet cannot swallow it) and a transient one is a banner.

## Tests

`AmperfyKitTests/Cases/PlaylistAdds/` — store CRUD and ordering, upload-service
success / permanent / transient / offline paths and retry, reconciler re-apply
and its no-op cases, failure classification, the local-first ordering both
routes now share, and the v53 → v54 migration.
`PlaylistAddSyncerTestDouble.swift` holds the recording `LibrarySyncer`.
