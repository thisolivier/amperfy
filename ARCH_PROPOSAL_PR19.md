# PR 19 — Unified Background Task Runner (Architecture Proposal)

Status: APPROVED 2026-04-17 — all open questions approved, major reframes below
Author: architect agent, 2026-04-15; updated 2026-04-17 with Olivier's sign-off
Scope: architecture only (no code). Settings UI design is a follow-up pass.

---

## Olivier's sign-off notes (2026-04-17, refined after discussion)

**All 5 open questions (§8) approved as proposed.**

**Primary goal: well-structured compute.** The main driver is ensuring
repeatable patterns for all three background algorithms, serialized so
they don't race on an aging device. The runner is load-bearing
infrastructure — Build 30's Jetsam kill is proof of what happens without
it. It must enforce serial execution, memory budgets, batched context
resets, and graceful failure (fail the task, not the app).

**Secondary goal: status observability.** While compute runs locally,
expose its status in Settings → Library: completed, in progress, pending,
last synced time, duration of last compute. Read-only — no run/cancel
controls.

**Server-side model (design constraint, not primary goal):** The future
is NOT "app triggers compute on server." The server will own when to run
calculations; the app receives/requests/syncs the computed state. The
three data tables (adjacency scores, playlist membership, album
completeness) would be synced on launch and periodically, alongside
normal library sync. In that world:

- The **data stores** are the permanent seam — they must be swappable
  between "filled by local runner" and "filled by Navidrome sync."
- The **runner gets dropped entirely** — replaced by tying into native
  Navidrome sync behaviour.
- The **status panel is a feature of the runner**, not of the stores.
  It goes away with the runner if/when server-side sync arrives.

The runner needs to be high quality (stable, memory-safe, crash-resilient)
but it doesn't need to be designed as a permanent architectural fixture.
It's reliable machinery for as long as we need it.

**Break into chunks:** PR 19 should be split into multiple focused sub-PRs
for more manageable planning and review.

---

## 1. Why Phase 2 was disabled

Olivier's hypothesis, logged in BACKLOG.md §19.3 (2026-04-16), was that Phase 2 was disabled "for performance — races or bottlenecks with the other background work". The git and release-note evidence **partially confirms but reframes** this:

**What the code says (`BackgroundLibrarySyncer.swift:153-156`, commit `11fec83`, 2026-04-13, Olivier, "Builds 29-32"):**
> Phase 2: Playlist item sync + adjacency recomputation DISABLED (Build 30 hotfix)
> These operations accumulate Core Data objects in memory (~2 GB on large libraries)
> causing Jetsam kills on physical devices. Will be re-enabled with batched/reset approach.

**What the release notes say (`Amperfy/SwiftUI/Settings/ReleaseNotes.swift` entries for Builds 30/32/33):**
- Build 32: "CRITICAL: Fixed Jetsam memory kill (~2.1 GB) that crashed the app within 20s of launch. Temporarily disabled background playlist item sync — root cause of unbounded memory growth."
- Build 33: Adjacency Engine v2 rebuild — SQLite-backed, windowed O(n×W), peak memory 154 MB → ~100 MB. The v2 rebuild addressed adjacency's own memory profile but did not re-enable Phase 2.

**Conclusion — challenge the hypothesis, narrow it.** Phase 2 was not disabled because of races or scheduling bottlenecks between the three processes. It was disabled because **the per-playlist `syncDown` path (`LibrarySyncerProxy.syncDown(playlist:)` → Subsonic/Ampache `getPlaylist`) accumulates unbounded `PlaylistItemMO` objects in a single Core Data context across N playlists**, and the follow-up `DefaultTrackAdjacencyService.invalidate() + computeIfNeeded()` kick (old v1 adjacency, in-memory JSON at that time) piled on top. Build 33's adjacency v2 SQLite rewrite fixed half of that problem — adjacency no longer bloats memory — but the playlist-item accumulation half was never re-approached. The existing `OperationQueue` already serializes these one at a time (`maxConcurrentOperationCount = 1`), so there is no *race*; the kill was pure memory growth within a single context over the full playlist corpus.

**Implication for PR 19.** The unified runner should not assume concurrency is the bottleneck. Phase 2's re-enable must attach a **per-playlist context reset / batched save** discipline. The runner gives us a place to enforce this uniformly, but the memory fix is in the Phase 2 task body, not in the queue.

---

## 2. Current state map

Three "heavy" processes run today, each plus their on-demand cousins:

```
AppDelegate.applicationDidFinishLaunching
  └── startManagerForNormalOperation  (MetaManager)
        └── backgroundLibrarySyncer.start()     [MetaManager.swift:283 & :293]
              └── BackgroundLibrarySyncer.start()
                    └── syncAlbumSongsInBackground()                    [Task]
                          ├── autoDownloadLibrarySyncer.syncNewestLibraryElements(...)  // newest-50 latest elements
                          ├── for albumsWithoutSyncedSongs:
                          │     taskQueue.addOperation(BackgroundSyncOperation { librarySyncer.sync(album:) })   // Phase 1
                          └── queuePlaylistItemSyncs()   // *** COMMENTED OUT line 156 ***
                                ├── for unsyncedPlaylists: taskQueue.addOperation(syncDown(playlist:))
                                └── taskQueue.addOperation(DefaultTrackAdjacencyService.invalidate + computeIfNeeded)

AppDelegate.applicationDidFinishLaunching
  └── computeTrackAdjacencyInBackground()   [AppDelegate.swift:441]
        └── DispatchQueue.global(qos:.utility).async {
              DefaultTrackAdjacencyService.shared.computeIfNeeded()
            }
```

**Where the three processes live:**
- **(1) Complete-album / library scan** — `AmperfyKit/Api/BackgroundLibrarySyncer.swift:107-160`, inside the `Task` in `syncAlbumSongsInBackground()`. Drives `librarySyncer.sync(album:)` for each album whose songs are unsynced (`getAlbumWithoutSyncedSongs()`).
- **(2) Playlist item sync** — `AmperfyKit/Api/BackgroundLibrarySyncer.swift:162-215` in `queuePlaylistItemSyncs()` (currently dead code). Drives `librarySyncer.syncDown(playlist:)` per playlist, with per-playlist state tracked in `PlaylistItemsSyncTracker` (UserDefaults-backed, `AmperfyKit/Storage/PlaylistItemsSyncTracker.swift`).
- **(3) Track adjacency scoring** — `AmperfyKit/Storage/TrackAdjacency/DefaultTrackAdjacencyService.swift`. Orchestrates `LocalTrackAdjacencyComputer` + `TrackAdjacencySQLiteStore`. Entry points today: `computeIfNeeded()` (skips if SQLite already has data), `invalidate()` + `computeFromScratch()`. Already protocol-separated (`PlaylistDataProvider`, `ScoredRelationSink`, `TrackAdjacencyQuerying`) — this was deliberate server-side seam groundwork.

**On-demand / lazy paths today (must be preserved):**
- `EntityPreviewVC.swift:734-756` — "Show in Playlists" lazily runs `librarySyncer.syncDown(playlist:)` for each unsynced playlist, with a 30 s cancel-all timeout, and marks synced via `PlaylistItemsSyncTracker`. This is the user-visible "feature comes online when tapped" path.
- `PlaylistDetailVC.swift:314` — Pull-to-refresh on a playlist detail screen calls `syncDown(playlist:)` for that playlist directly.
- `Playlist.fetchFromServer(...)` in `AmperfyKit/Storage/EntityWrappers/Playlist.swift:521` — generic entity refresh.
- Related Tracks screen (`RelatedTracksVC.swift`) reads adjacency synchronously; no compute trigger from there today — it relies on the background compute + stale-reads.

**Existing infrastructure worth reusing:**
- `AsyncOperation` (`AmperfyKit/Common/AsyncOperation.swift`) — KVO-correct `Operation` subclass with async `main`.
- `OperationQueue` with `maxConcurrentOperationCount = 1` inside `BackgroundLibrarySyncer`. This is already a serial runner — we are effectively generalizing it, not replacing it.
- `Atomic<T>` for flags, `AsyncCoreDataAccessWrapper` / `newBackgroundContext()` for per-task Core Data contexts.
- `MemoryReporter` for checkpoint logging.
- `EventLogger` for user-facing error surfacing.

**No status surface today.** `BackgroundLibrarySyncer.isActive` is queried internally only. Adjacency exposes `isStale` but no timestamps or error state. Nothing is observable to the Settings layer.

---

## 3. Proposed runner

### 3.1 Shape at a glance

```
                ┌─────────────────────────────────────────┐
                │          BackgroundTaskRunner           │   (AmperfyKit/BackgroundRunner/)
                │  - enqueue(TaskDescriptor)              │
                │  - runNow(TaskKind)                     │
                │  - cancel(TaskKind)                     │
                │  - statePublisher: AnyPublisher<...>    │
                └──────────────┬──────────────────────────┘
                               │ picks executor per descriptor
                               ▼
                ┌─────────────────────────────────────────┐
                │            TaskExecutor                 │   (protocol — THE SEAM)
                │  execute(descriptor, progress, cancel)  │
                └──────┬──────────────────────────┬───────┘
                       │                          │
         ┌─────────────▼───────────┐  ┌───────────▼─────────────┐
         │  LocalTaskExecutor      │  │  RemoteTaskExecutor     │
         │  (today, on-device)     │  │  (future, HTTP-backed)  │
         └─────────────────────────┘  └─────────────────────────┘
                       │
        ┌──────────────┼───────────────────┐
        ▼              ▼                   ▼
  AlbumScanWorker  PlaylistSyncWorker  AdjacencyWorker
```

Three nouns matter:

- **`TaskKind`** — an enum, stable identity. `.albumScan`, `.playlistItemSync`, `.adjacencyCompute`. The status store keys off this.
- **`TaskDescriptor`** — a value type describing *what* to run: kind, trigger reason (`.scheduled`, `.userRequested`, `.invalidation`), inputs (scope: full / subset / single-id), priority. Crucially, it contains **no closures and no references to Core Data or network objects** — it is serializable, so a future remote executor can ship it over the wire.
- **`TaskExecutor`** — a protocol that takes a `TaskDescriptor` and produces a stream of progress/terminal events. Today's impl is `LocalTaskExecutor`, which hands off to a per-kind worker. Tomorrow's impl can be `RemoteTaskExecutor` that POSTs the descriptor and polls/streams results.

### 3.2 Task definition protocol

```
protocol BackgroundTaskWorker {
  var kind: TaskKind { get }
  var memoryProfile: MemoryProfile { get }   // .light / .heavy — scheduler uses this
  var cooperatesWith: Set<TaskKind> { get }  // empty = must run solo; others it tolerates

  // Executed by the LocalTaskExecutor. Must be re-entrant-safe (cancellable mid-flight)
  // and must periodically yield via `context.checkpoint()` so progress/cancel flow.
  func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws -> TaskSummary
}
```

`TaskRunContext` gives the worker: a scoped Core Data background context, a progress callback (`.started`, `.progress(done, total)`, `.checkpoint(label)`), `Task.isCancelled`-style cancel probe, network-reachability gate, and a throttle primitive (`await context.throttleIfNeeded()`) that the scheduler can use to pause heavy workers under memory pressure.

**The three workers in proposal form — no code, just their shape:**
- **`AlbumScanWorker`** (Phase 1). Descriptor input: scope (`.all` by default; `.album(id:)` supported for "Run now"). Queries `getAlbumWithoutSyncedSongs()`, loops `librarySyncer.sync(album:)` per album. Already well-behaved; minor changes (progress reporting + checkpoint + descriptor input).
- **`PlaylistSyncWorker`** (Phase 2 re-enable). Descriptor input: scope (`.allUnsynced` default; `.playlist(id:)` for single-playlist lazy path). **Mandatory batched-reset discipline:** each N playlists (N=5-10), perform `context.reset()` on its scoped background context to release accumulated `PlaylistItemMO`s — this is the missing fix from Build 30. Marks `PlaylistItemsSyncTracker` on success. On completion, enqueues `.adjacencyCompute(trigger: .invalidation)` if the scope was broad.
- **`AdjacencyWorker`**. Descriptor input: `.ifNeeded` (respect `isStale`) or `.force` (invalidate + recompute). Calls `DefaultTrackAdjacencyService.computeIfNeeded()` or `invalidate()` + `computeFromScratch()`. The existing `PlaylistDataProvider` / `ScoredRelationSink` seam stays intact.

### 3.3 Executor protocol (the server-side seam)

```
protocol TaskExecutor {
  func execute(
    descriptor: TaskDescriptor,
    events: TaskEventSink
  ) async throws -> TaskSummary
}
```

The executor is the only layer that knows *how* a task runs. The runner above it only knows that it gave a descriptor and got events back. This is the hinge for §4 (server-side).

`LocalTaskExecutor` holds a `[TaskKind: BackgroundTaskWorker]` registry and dispatches. `RemoteTaskExecutor` will wrap an HTTP/RPC client and stream events back via long-poll or SSE (design choice deferred to a later PR).

### 3.4 Scheduling policy

**Recommendation: serial-by-default with a "light" fast-lane.**

- Single `OperationQueue`, `maxConcurrentOperationCount = 1` — reuse today's pattern. It works. It already prevents the race concern Olivier raised. The Build 30 kill was memory, not concurrency.
- Workers declare a `MemoryProfile`. All three current workers are `.heavy` and therefore serialize.
- Reserve a **"fast lane" secondary queue** (concurrency=1) for `.light` descriptors only — for example, a future "single-playlist lazy sync" descriptor that the on-demand path can enqueue without being blocked behind a full album scan. Not used by the initial three workers — but it's the spine for the lazy-sync integration in §3.7.
- **Priority:** descriptors carry `TaskPriority` (`.userInitiated` / `.background`). A `.userInitiated` descriptor preempts the current `.background` descriptor of the same kind by cancelling it and re-enqueueing. We do not preempt across kinds (too much state to unwind mid-compute).
- **Dependency chaining** is expressed in descriptors (`dependsOn: [TaskKind]`), not by the workers enqueuing each other. Today `queuePlaylistItemSyncs()` tail-chains an adjacency op inside its own body; under the new runner, `PlaylistSyncWorker` returns a `TaskSummary` with `suggestedFollowups: [.adjacencyCompute(.invalidation)]` and the runner decides whether to enqueue it (respecting feature flags and dedup).
- **No time-slicing / no parallelism across kinds** in v1. If future profiling shows adjacency and album scan can safely run in parallel on modern devices, we lift the limit behind a flag — but not now.

### 3.5 State, transitions, observers

```
TaskStatus = .idle
           | .queued(since: Date)
           | .running(since: Date, progress: Progress?)
           | .completed(at: Date, summary: TaskSummary)
           | .failed(at: Date, error: String)
           | .disabled(reason: String)        // e.g. Phase 2 off via flag
```

- `BackgroundTaskStatusStore` — single source of truth, keyed by `TaskKind`. UserDefaults-backed for terminal states (`.completed`, `.failed`, `.disabled`), in-memory only for transient (`.queued`, `.running`). Matches BACKLOG.md §19.3's shape.
- Publishes via Combine (`@Published` or `CurrentValueSubject<[TaskKind: TaskStatus], Never>`). The Settings panel binds directly; no polling.
- Transitions are emitted by the runner, not by workers. Workers only emit progress/error through their `TaskEventSink`; the runner translates those into status transitions. This keeps workers simple and keeps the store consistent even if a worker crashes mid-run.

### 3.6 Feature flag plumbing

Single `BackgroundRunnerFeatureFlags` struct, UserDefaults-backed, read at enqueue time:

- `phase2Enabled: Bool` (default **false** for the first ship — stays opt-in until QA confirms memory profile on large libraries). When false, the runner reports `.disabled(reason: "Phase 2 off — using on-demand lazy sync")` for `.playlistItemSync`.
- `adjacencyAutoCompute: Bool` (default true). Lets QA disable auto-adjacency if it ever regresses.
- `runnerEnabled: Bool` (default true). Kill-switch that bypasses the runner entirely and falls back to the pre-PR-19 direct code paths — critical rollback lever if the runner itself misbehaves. Achieved by keeping the old `BackgroundLibrarySyncer.syncAlbumSongsInBackground()` body reachable under the flag (see §6 migration).

Flags surface in Settings → Developer (behind the existing developer toggle). Not user-facing defaults until Phase 2 stabilizes.

### 3.7 On-demand / lazy path integration

The existing lazy-sync paths are preserved unchanged:

- `EntityPreviewVC.swift:734-756` — "Show in Playlists" lazily runs
  `syncDown(playlist:)` per unsynced playlist. Stays as-is.
- `PlaylistDetailVC.swift:314` — Pull-to-refresh calls `syncDown(playlist:)`
  directly. Stays as-is.

These paths do NOT route through the runner. The runner is for scheduled
background work; on-demand user-initiated syncs keep their direct paths.
If a lazy sync and a runner-scheduled sync overlap on the same playlist,
the existing `PlaylistItemsSyncTracker.markInFlight(id)` gate prevents
double-sync (Risk §7.3).

### 3.8 Where PR 19's Settings status panel plugs in

- New file `Amperfy/SwiftUI/Settings/BackgroundTasksSection.swift`, a
  SwiftUI `Section` composed into the existing `LibrarySettingsView`.
- Binds to `BackgroundTaskStatusStore.shared` via Combine. Three rows
  wired to `.albumScan`, `.playlistItemSync`, `.adjacencyCompute`.
- Each row shows: status (completed/in-progress/pending/failed/disabled),
  last synced timestamp, duration of last compute.
- **Read-only. No run/cancel controls.** Debug/observability only.

---

## 4. Server-side seam (REFRAMED per Olivier 2026-04-17)

**The future model:** The server owns when to run calculations (adjacency,
is-complete-album, is-in-playlist). The app syncs the *computed results*
on launch and periodically, alongside normal library sync — the same way
it syncs albums, artists, and songs today. The app never triggers compute.

**The seam is at the data stores, not the executor.**

The three data stores (adjacency scores, playlist membership, album
completeness) are the permanent interfaces. Today they're filled by the
runner's local compute; tomorrow they'd be filled by Navidrome sync. The
consumer code (UI, query builders) reads from the stores and doesn't care
how they got populated.

**What this means for PR 19 design:**
- The `TaskExecutor` protocol is useful internal structure for the runner,
  but it is NOT the server-side seam. When server sync arrives, the whole
  runner (executor, descriptors, workers) gets dropped — not swapped.
- The stores are the seam. Each store's write interface must be clean
  enough that a sync adapter can fill it directly from a server response.
- Don't over-engineer the executor/descriptor layer for remote concerns
  (no serializable descriptors for wire transport, no SSE streaming).
  Keep them pragmatic for the local-compute job they actually do.

**Why the three current stores are already close:**
- **Adjacency** — `TrackAdjacencySQLiteStore` has a clean write path
  (`insertOrUpdate(pairs:)`). A sync adapter would call the same method
  with server-sourced pairs. Ready.
- **Playlist membership** — Core Data `PlaylistItemMO` relationships.
  `syncDown(playlist:)` already writes these from server data. In the
  server-side future, a bulk endpoint replaces the N per-playlist calls
  but the write path is the same. Ready.
- **Album completeness** — `remoteSongCount` on `AlbumMO`. Already set
  by the library syncer from Navidrome's album metadata. The "scan" just
  triggers fetching songs for albums whose count is unknown. Ready.

---

## 5. Trade-offs considered

**Alternative A: Actor-based runner with Swift Concurrency only (no OperationQueue).**
Cleaner on paper — `actor BackgroundTaskRunner` with a serial queue of `async` workers. Rejected because (1) the existing `OperationQueue` already works, is KVO-introspectable, and integrates with `UIApplication.beginBackgroundTask(...)` cleanly, which matters for letting Phase 1 keep running briefly when the app backgrounds; (2) actor isolation would force us to re-plumb the Core Data `@MainActor` boundaries that `BackgroundLibrarySyncer` currently threads carefully; (3) we'd lose `cancelAllOperations()` and `addBarrierBlock` for free.

**Alternative B: Combine pipeline end-to-end (publisher-based scheduler).**
Tempting because the status observers are Combine anyway. Rejected because running long-lived async work inside a Combine chain with cancellation semantics gets awkward fast (publishers want per-subscription cancellation; we want per-task cancellation). Combine is the right answer for *observation* (status store → UI), but the wrong primitive for *execution* (use `Task` or `Operation`).

**Alternative C: Leave `BackgroundLibrarySyncer` alone, bolt on a thin `BackgroundTaskStatusStore` and call it done.**
This is the minimum PR 19. Rejected because (1) Olivier explicitly asked for the architecture to be amenable to server-side execution — a bolt-on status store gives zero seam for that; (2) re-enabling Phase 2 without the batched-reset discipline will re-crash; (3) we'd keep three separate trigger/cancel paths that the status panel would have to mirror-maintain, which is more fragile than centralizing. The unified runner is marginally more work now for a much better platform for the next three PRs.

---

## 6. Migration plan

Superseded by §9 (chunked implementation plan). The original 7-step plan
is preserved below for reference but §9 is authoritative.

<details>
<summary>Original 7-step plan (pre-approval)</summary>

**Step 1 — Status store only.** Add `BackgroundTaskStatusStore`, instrument existing call sites, wire Settings panel. Phase 2 stays disabled.

**Step 2 — `TaskDescriptor` / `TaskExecutor` / `BackgroundTaskRunner` skeleton.** Define types, unit tests. Zero behaviour change.

**Step 3 — Migrate Phase 1 (album scan) behind `runnerEnabled` flag.**

**Step 4 — Migrate adjacency.**

**Step 5 — Re-enable Phase 2 behind `phase2Enabled` flag (default OFF).**

**Step 6 — "Run now" triggers + lazy-path status tracking.** (Note: Olivier's sign-off removed "Run now" controls — Settings is status-only.)

**Step 7 — Cleanup.** Delete pre-runner code paths.

</details>

---

## 7. Risks

1. **Phase 2 memory regression returns.** The batched-reset discipline in `PlaylistSyncWorker` is theory until profiled. *Mitigation:* Step 5 ships behind a default-OFF flag; Olivier validates on his ~2 GB-kill library before broader rollout. Add `MemoryReporter` checkpoints around every batch boundary, fail the task (not the app) if peak exceeds a budget.

2. **Runner introduces a new kind of bug — status drift.** Store says "running" forever because a worker crashed without emitting a terminal event. *Mitigation:* the runner — not the worker — owns the transition. A watchdog timer on each `running` state flips to `.failed("timeout")` after a per-kind ceiling (e.g. 15 min for album scan, 5 min for adjacency). Also: app-launch sweep that resets any `.running` entry from a prior session to `.failed("interrupted")`.

3. **Lazy-path + runner double-sync.** User taps "in playlist" while the background runner is also mid-sync on the same playlist. Two `syncDown(playlist:)` fire in parallel, Core Data conflicts. *Mitigation:* `PlaylistItemsSyncTracker.markInFlight(id)` gate — both paths consult it. This is a small extension to the existing tracker, not new infrastructure.

4. **Server-side seam underbakes.** We ship `TaskExecutor` as a protocol but the first remote executor reveals `TaskDescriptor` is missing fields (auth scope, server version, idempotency key). *Mitigation:* explicitly scope §4 as "seam exists, wire format TBD in future PR". The descriptor type is internal-only until a remote PR; we can grow it freely.

5. **Operation cancellation under app-backgrounding.** iOS suspends the app mid-Phase-1; existing `beginBackgroundTask` extension is in `BackgroundLibrarySyncer` today. If we refactor without carrying it through, Phase 1 starts dying silently at scenes/backgrounding. *Mitigation:* the runner owns the `UIApplication.beginBackgroundTask` lifecycle, not the workers. One place to get it right, checked in Step 3 against current behaviour.

---

## 8. Open questions — RESOLVED (2026-04-17)

All 5 approved as proposed. Additionally:
- **No run/cancel controls in Settings.** Status + last-synced only.
- **Break into chunks** for focused planning (see §9).

1. ✅ Runner core in AmperfyKit, UIKit lifecycle bridge in app target.
2. ✅ Singleton runner, account-scoped descriptors, store keys by `(accountId, kind)`.
3. ✅ Phase 2 defaults ON once profiled stable.
4. ✅ All-unsynced scope (no "Run now" button — status-only panel).
5. ✅ Always kick adjacency after Phase 2, using `computeIfNeeded()`.

---

## 9. Chunked implementation plan (per Olivier's request)

PR 19 is split into focused sub-PRs. Each is independently shippable.
The runner is the central deliverable; the status panel is a window into
it. Stores are kept clean for future server-sync replacement but we don't
add abstraction layers for that — the stores are already in good shape.

### PR 19a — Runner skeleton + status store + status panel

Build the runner infrastructure and the status panel in one piece so
there's something end-to-end to see immediately.

- `BackgroundTaskRunner`: serial `OperationQueue`-backed, owns task
  lifecycle, enforces memory budgets, manages `beginBackgroundTask`.
- `TaskDescriptor`, `TaskKind`, `BackgroundTaskWorker` protocol.
- `BackgroundTaskStatusStore` (UserDefaults-backed for terminals,
  Combine-published). Tracks per-kind: completed/in-progress/pending/
  failed, last synced time, duration of last compute.
- Read-only Settings → Library panel showing status for each task kind.
  Phase 2 row shows "disabled." No run/cancel controls.
- Feature flags: `phase2Enabled` (OFF), `runnerEnabled` kill-switch (ON).
- Unit tests for status transitions, queue serialization, descriptor
  equality.

**Deliverable:** runner infrastructure exists, status panel visible.
No workers migrated yet — status panel shows idle/disabled states.

### PR 19b — Migrate Phase 1 (album scan) behind runner

Extract the album scan body from `syncAlbumSongsInBackground()` into
`AlbumScanWorker`. Entry point now calls `runner.enqueue(.albumScan)`.
Old code path stays reachable behind `runnerEnabled = false`. Status
panel now reports album scan live.

**Deliverable:** one real worker proving the runner. Album scan status
visible in Settings.

### PR 19c — Migrate adjacency behind runner

Move `computeTrackAdjacencyInBackground()` into `AdjacencyWorker`.
Remove the `DispatchQueue.global` call from AppDelegate. Status panel
reports adjacency live.

**Deliverable:** two of three workers behind the runner. Adjacency
status visible.

### PR 19d — Phase 2 re-enable (batched playlist sync)

Add `PlaylistSyncWorker` with per-N-playlists `context.reset()` to fix
the Build 30 memory kill. Migrate behind the runner. Default OFF behind
`phase2Enabled` flag. On completion, auto-kick adjacency via
`computeIfNeeded()`. Profile on Olivier's device. Once stable, flip
default to ON.

**Deliverable:** playlist sync back online, memory-safe. All three
workers unified under the runner.

### PR 19e — Cleanup

Delete pre-runner code paths. `BackgroundLibrarySyncer` becomes a thin
shell or is folded into the runner module. Remove `runnerEnabled`
kill-switch (runner is the only way in).
