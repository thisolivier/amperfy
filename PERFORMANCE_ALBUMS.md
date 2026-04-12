# Albums view performance — investigation notes (2026-04-11)

## Symptom

Library -> Albums view on Olivier's aging iPhone shows high lag tapping in/out
of album detail, high lag scrolling the section index strip, and occasional lag
on the top-level Library root. The user reports "the lag remains long after the
recalculation" — switching from the Complete albums filter to the unfiltered
list is the trigger but the lag persists after the FRC has stabilized. One
crash was observed (no stack trace captured). The simulator does not reproduce
the lag, consistent with a CPU/memory-pressure problem masked by the host Mac's
resources.

## Methodology

Static analysis only. Read the following call graph:

- `AlbumsVC` (table VC subclass, 314 lines) + `AlbumsCommonVCInteractions`
  (shared logic, 643 lines)
- `AlbumsDiffableDataSource` — data source with `sectionIndexTitles`,
  `titleForHeaderInSection`, `sectionForSectionIndexTitle`
- `SingleSnapshotFetchedResultsTableViewController` — snapshot-driven
  `controller(_:didChangeContentWith:)` delegate
- `CachedFetchedResultsController` + `BasicFetchedResultsController` —
  two-controller pattern (allFetchResulsController / searchFetchResulsController)
- `CustomSectionIndexFetchedResultsController` — FRC subclass with custom
  `sectionIndexTitle(forSectionName:)`
- `AlbumFetchedResultsController` — init predicate composition, `search()`
  override for whole-album clause
- `GenericTableCell` — cell configuration via `EntityImageView.display()`
- `LibraryEntityImage` — artwork loading with `NSCache` + `Task.detached`
- `WholeAlbumPredicates` — the `CONTAINS[c]` predicate under examination
- `AlbumMO+CoreDataProperties` — `relationshipKeyPathsForPrefetching`

No Instruments runs or device attach in this pass.

## Hypotheses tested

### H1: Stale post-swap state in the FRC / snapshot

The "Complete albums" toggle calls `change(sortType:)` which:
1. Calls `fetchedResultsController?.clearResults()` (sets predicate to `false`,
   re-fetches to clear)
2. Creates a **brand-new** `AlbumFetchedResultsController`
3. Reassigns `singleFetchedResultsController` and its delegate via
   `updateFetchDataSourceCB`
4. Calls `fetchedResultsController.fetch()`

This is clean — the old FRC is discarded entirely, not mutated. The
`CachedFetchedResultsController` uses two internal FRCs
(`allFetchResulsController` for default, `searchFetchResulsController` for
search), both freshly constructed in `init`. There is no reuse of a stale
snapshot.

**However**, the snapshot delegate `controller(_:didChangeContentWith:)` at
`SingleSnapshotFetchedResultsTableViewController:152` does an
**O(n) scan** over all item identifiers to find reconfigure candidates:

```swift
let reloadIdentifiers: [NSManagedObjectID] = snapshot.itemIdentifiers
  .compactMap { itemIdentifier in
    guard let currentIndex = currentSnapshot.indexOfItem(itemIdentifier),
          let index = snapshot.indexOfItem(itemIdentifier),
          index == currentIndex else { return nil }
    guard let existingObject = try? controller.managedObjectContext
      .existingObject(with: itemIdentifier),
      existingObject.isUpdated else { return nil }
    return itemIdentifier
  }
```

For every item in the new snapshot, this calls `existingObject(with:)` which
may fault the managed object. On a 500+ album library, this is 500+
`existingObject` calls per snapshot update. The `isUpdated` check then touches
the object's change tracking. This fires on every FRC update, including
background sync merges.

The `dataSource.apply(snapshot, animatingDifferences: false)` call itself
is relatively cheap with `animatingDifferences: false`, but the
reconfigure-candidate scan preceding it is not.

- Evidence for: O(n) scan with potential faulting per snapshot update
- Evidence against: `returnsObjectsAsFaults = false` + prefetching is set on
  the fetch request, so after the initial fetch most objects should be in-memory
- Verdict: **likely contributor** — the scan is O(n) per update, and background
  sync can trigger many updates in quick succession

### H2: Artwork decode on cell-render

`GenericTableCell.display()` calls `entityImage.display(theme:container:)`
which flows to `LibraryEntityImage.displayAndUpdate(entity:)` ->
`display(entity:)` -> `refresh()`.

The `refresh()` method:
1. Checks `NSCache` (static, shared across all cells) — cache hit is O(1)
2. On cache miss: sets placeholder image synchronously, then dispatches
   `Task.detached(priority: .high)` to load + decode asynchronously via
   `UIImage(contentsOfFile:)` + `byPreparingForDisplay()`

This is well-structured — image decode is off the main thread. The
`byPreparingForDisplay()` call pre-renders the image on a background thread
before assigning to the image view.

**But**: the `downloadFinishedSuccessful(notification:)` observer is registered
per-cell-image-view and fires for **every** artwork download completion
notification. If background sync triggers N artwork downloads, every visible
LibraryEntityImage receives N notifications, each checking if the download
matches. With M visible cells and N downloads, this is O(M*N) notification
dispatches. This is not a cell-render issue per se, but a notification storm
during sync.

- Evidence for: notification storm during background sync could block main
  thread
- Evidence against: the per-notification work is lightweight (two ID
  comparisons); async image load is off-thread
- Verdict: **unlikely as primary cause**, but the O(M*N) notification pattern
  could amplify during heavy sync windows

### H3: Section-index scroll recomputes the full section titles

`AlbumsDiffableDataSource.sectionIndexTitles(for:)` (line 76) iterates from
`0 ... sectionCount` — that's **0 to sectionCount inclusive**, an off-by-one
that processes `sectionCount + 1` iterations. Each iteration calls
`self.tableView(tableView, titleForHeaderInSection: i)` which in turn calls
`getFirstAlbum(in: section)` -> `getAlbum(at: IndexPath(row: 0, section: i))`
-> `itemIdentifier(for:)` -> `existingObject(with:)`.

This means **every call to `sectionIndexTitles`** materializes the first
`AlbumMO` of every section. With sort-by-name on a 500-album library, that's
~26 sections = ~27 `existingObject` calls. With sort-by-year, it could be
50-80 sections (one per distinct year/nil).

`sectionIndexTitles(for:)` is called by `UITableView` on every layout pass,
including during scroll. It is **not cached** by the data source — the array
is recomputed each time.

The off-by-one (`0 ... sectionCount` instead of `0 ..< sectionCount`)
causes an out-of-bounds access on each call. `getFirstAlbum(in:
sectionCount)` returns nil (because `itemIdentifier(for:)` returns nil for
an invalid index path), so it doesn't crash, but it's still a wasted lookup
per layout pass.

`tableView(_:sectionForSectionIndexTitle:at:)` just returns `index` directly
— this is correct and O(1).

- Evidence for: uncached O(sections) computation per layout pass, with
  managed object materialization per section; off-by-one adds wasted work
- Evidence against: 26 object lookups at ~microseconds each is likely under
  1ms total; not the primary lag source
- Verdict: **likely minor contributor** — not the smoking gun alone, but adds
  up when combined with rapid layout passes during scroll/animation. The
  off-by-one is a correctness bug regardless.

### H4: Core Data fault storms

The `AlbumFetchedResultsController` init sets:
```swift
fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
fetchRequest.returnsObjectsAsFaults = false
```

`AlbumMO.relationshipKeyPathsForPrefetching` is `["artwork", "artist"]` — the
two relationships needed for cell display (`entityImage` needs artwork,
`subtitle` needs artist name).

With `returnsObjectsAsFaults = false`, the initial `performFetch()` fully
materializes all matching AlbumMO objects into memory. Subsequent access
should not fault.

**But** there are paths that bypass the FRC and re-fetch:
- `handleHeaderPlay()` and `handleHeaderShuffle()` (lines 553-578) iterate
  `fetchedObjects` and call `Album(managedObject:)` + `.playables` on each.
  `.playables` traverses `songs` -> each SongMO. This is a fault storm on
  the songs relationship, which is NOT in the prefetch list for the list-level
  FRC (only in `relationshipKeyPathsForPrefetchingDetailed`).
- `displayedSongs` (line 545) iterates ALL fetched albums and expands all
  songs — this is O(albums * avg_songs). On a 500-album library with avg 10
  songs, that's 5000 SongMO faults.

These are triggered by the header Play/Shuffle buttons, not by scroll, so
they're not the scroll-lag source. But if the header's `infoCB` (line 601)
is called during layout, it accesses `fetchedObjects?.count` which should be
cheap (count of already-fetched array).

- Evidence for: `displayedSongs` and `handleHeaderPlay/Shuffle` trigger fault
  storms on the songs relationship
- Evidence against: these are user-initiated actions (play/shuffle button),
  not scroll-driven; the FRC's initial fetch is properly de-faulted
- Verdict: **unlikely for scroll lag** — but `handleHeaderPlay/Shuffle` have
  a latent performance problem that would manifest as a hang on the play
  button in a large library

### H5: The `CONTAINS[c]` predicate is non-SARGable on SQLite

`WholeAlbumPredicates.wholeAlbum(minSongCount:)` uses:
```sql
(releaseType == nil OR NOT (releaseType CONTAINS[c] 'single'))
AND remoteSongCount >= 3
```

`CONTAINS[c]` maps to SQLite `LIKE '%single%'` (case-insensitive), which
cannot use a btree index and requires a full table scan of the `releaseType`
column. On a 500-album library this is ~500 string comparisons.

**However**, this predicate fires only:
1. At FRC construction time (in `init`, once per toggle or sort change)
2. At `search()` time (once per search text change)

It does NOT fire on every scroll — `NSFetchedResultsController` caches the
result set after `performFetch()` and uses change notifications (not
re-fetching) for updates. The FRC's `performFetch()` runs one SQLite query;
subsequent cell accesses use the in-memory object graph.

The predicate is also composed with `remoteSongCount >= 3` which IS
SARGable if there's an index on `remoteSongCount`. SQLite's query optimizer
may short-circuit the `CONTAINS[c]` branch by filtering on count first, but
this depends on statistics.

The `releaseType == nil OR ...` guard (added in Hotfix 2) adds an OR branch
that prevents index use on `releaseType` alone, but this is intentional
NULL-safety — without it, nil-metadata albums are silently excluded.

- Evidence for: `CONTAINS[c]` is a table scan; the OR guard prevents index
  optimization
- Evidence against: fires once at fetch time, not per-scroll; 500 rows is
  trivial for SQLite even with a scan (~1ms)
- Verdict: **not the lag source** — confirmed: predicate is one-shot, not
  re-evaluated on scroll

### H6 (emergent): Snapshot reconfigure scan during background sync

Discovered during H1 analysis. The `controller(_:didChangeContentWith:)`
delegate method runs an O(n) scan of all items in the new snapshot, calling
`existingObject(with:)` and checking `isUpdated` for each. Background sync
(artwork downloads, metadata refreshes) can trigger this delegate method
repeatedly in quick succession.

If the sync merges changes every few seconds (e.g., artwork download
completion → context save → merge notification → FRC update → delegate
callback), the main thread gets hit with repeated O(500) scans. Each scan
does ~500 `existingObject` calls + `isUpdated` checks. At ~1ms per scan,
10 rapid-fire updates = 10ms of main-thread work in a short window — enough
to cause perceptible jank during scroll.

- Evidence for: O(n) per delegate callback, repeated during sync
- Evidence against: with `returnsObjectsAsFaults = false`, the
  `existingObject` calls should be cheap (in-memory lookup, not a fault)
- Verdict: **likely contributor during sync windows** — the scan itself is
  fast per-call, but rapid-fire triggering during background sync could
  accumulate

### H7 (emergent): Toggle destroys and rebuilds entire FRC

When the user taps "Complete albums only", `change(sortType:)` creates a
brand-new `AlbumFetchedResultsController`, which allocates two fresh FRCs
internally (`CachedFetchedResultsController` creates both
`allFetchResulsController` and `searchFetchResulsController` in init). Each
FRC gets a copy of the fetch request and performs a full SQLite fetch.

The `allFetchResulsController` uses a **disk-backed cache** (cache name:
`"CachedFetchedResultsController-{serverHash}-{userHash}"`). But the
toggle creates a new controller with the same cache name, which triggers
`NSFetchedResultsController`'s cache invalidation — the old cache is
discarded and rebuilt from the new fetch results.

On a 500-album library, this means:
1. SQLite query (with the `CONTAINS[c]` predicate) — ~1-5ms
2. Materialize 500 `AlbumMO` objects with prefetched artwork + artist — ~10-50ms
3. Rebuild FRC section cache — ~5-20ms
4. Diffable data source snapshot apply — triggers the O(n) reconfigure scan

Total: ~20-80ms on a modern iPhone, potentially 200-500ms+ on an aging device
with thermal throttling.

- Evidence for: full FRC rebuild + cache invalidation + O(n) snapshot apply
  per toggle
- Evidence against: this is a one-shot cost on toggle, not per-scroll
- Verdict: **likely cause of toggle-specific lag** — the "recalculation" lag
  the user reports. Subsequent scroll lag has a different cause (see Findings).

## Findings

### F1: The primary scroll-lag suspect is the uncached `sectionIndexTitles` recomputation

`AlbumsDiffableDataSource.sectionIndexTitles(for:)` (AlbumsVC.swift:76) is
called by UIKit on every layout pass. It iterates all sections, materializing
the first album of each section via `existingObject(with:)`. This is fast
individually but adds up during rapid scrolling with layout invalidation.

Additionally, it has an **off-by-one bug**: `for i in 0 ... sectionCount`
should be `for i in 0 ..< sectionCount`. This causes one extra wasted
`getFirstAlbum` call per invocation that always returns nil.

**File:line**: `Amperfy/Screens/ViewController/AlbumsVC.swift:79`

### F2: The O(n) reconfigure scan in the snapshot delegate is the primary sync-window lag suspect

`SingleSnapshotFetchedResultsTableViewController.controller(_:didChangeContentWith:)`
at line 152 iterates all snapshot items and calls `existingObject(with:)` +
`isUpdated` for each. During background sync this fires repeatedly.

**File:line**: `Amperfy/Screens/ViewController/TableViewHelper/SingleSnapshotFetchedResultsTableViewController.swift:170-179`

### F3: The FRC rebuild on toggle is the "recalculation lag" source

`AlbumsCommonVCInteractions.change(sortType:)` at line 197 creates a new FRC,
re-fetches, and triggers a full snapshot diff. On an aging device this can take
200-500ms.

**File:line**: `Amperfy/Screens/ViewController/AlbumsCommonVCInteractions.swift:197-220`

### F4: `handleHeaderPlay/Shuffle` has a latent O(albums*songs) fault storm

Lines 553-578 iterate `fetchedObjects` and expand `.playables` (which traverses
the `songs` relationship). The `songs` relationship is NOT in the list-level
prefetch set. This would manifest as a multi-second hang on the play button in
a large library.

**File:line**: `Amperfy/Screens/ViewController/AlbumsCommonVCInteractions.swift:553-578`

### F5: Artwork loading is well-structured (not a primary issue)

`LibraryEntityImage` uses `NSCache` + `Task.detached` + `byPreparingForDisplay()`
correctly. Cache hits are O(1). The notification-per-download pattern could
amplify during sync but is lightweight per-call.

**File:line**: `AmperfyKit/Screens/LibraryEntityImage.swift:159-189`

### F6 (correctness): Off-by-one in sectionIndexTitles

`for i in 0 ... sectionCount` iterates one past the last valid section.
`getFirstAlbum(in: sectionCount)` returns nil (no crash), but the `if let`
guard means the extra iteration is a silent no-op. Still a bug.

**File:line**: `Amperfy/Screens/ViewController/AlbumsVC.swift:79`

## Recommended follow-ups

1. **Cache `sectionIndexTitles` result** (effort: small, risk: low).
   Compute the index titles array once after each `snapshotDidChange` callback
   and return the cached value from `sectionIndexTitles(for:)`. Fix the
   off-by-one (`0 ..< sectionCount`) at the same time. This eliminates per-
   layout-pass O(sections) work.

2. **Skip reconfigure scan when no objects are updated** (effort: small,
   risk: low). In the snapshot delegate, short-circuit the `compactMap` when
   the incoming snapshot has no updated objects (check
   `controller.managedObjectContext.updatedObjects.isEmpty` before iterating).
   This eliminates the O(n) scan during insert-only background sync updates.

3. **Throttle FRC delegate callbacks during sync** (effort: medium,
   risk: medium). Coalesce rapid-fire snapshot updates into a single apply
   with a small debounce (e.g., 100ms). UIKit's `NSDiffableDataSourceSnapshot`
   handles batch diffs well; the bottleneck is the per-update reconfigure scan.

4. **Fix `handleHeaderPlay/Shuffle` to limit fault scope** (effort: small,
   risk: low). Already limits to `prefix(5)` albums, but still expands
   `.playables` (which faults `songs`). Consider prefetching `songs` only for
   the 5 selected albums, or using a separate fetch request with
   `relationshipKeyPathsForPrefetchingDetailed`.

5. **Device profiling session** (effort: medium, risk: none). Attach
   Instruments to Olivier's phone and capture a Time Profiler + Core Data
   trace during the Albums toggle + scroll sequence. This would confirm
   whether F1 or F2 dominates wall-clock time on the actual device and whether
   thermal throttling amplifies the effect.
