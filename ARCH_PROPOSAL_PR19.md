# PR 19 — Unified Background Task Runner (Architecture Proposal)

Status: draft, awaiting sign-off
Author: architect agent, 2026-04-15
Scope: architecture only (no code). Settings UI design is a follow-up pass after sign-off.

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

### 3.7 On-demand trigger path integration

Two flavors, both preserved:

1. **"Run now" from the Settings status panel.** Enqueue a `TaskDescriptor` with `.userInitiated` priority and scope `.all` (for album scan / adjacency) or `.allUnsynced` (for playlist sync). Re-entrant: if the same-kind task is already running, the request is coalesced (no double-enqueue).

2. **Lazy sync from in-playlist lookup / pull-to-refresh.** These are *narrow-scope* descriptors: `.playlistItemSync(scope: .playlist(id: "abc"))` with `.userInitiated` priority and `.light` memory profile. They go through the fast-lane queue so they never wait behind a background album scan. **The existing call sites in `EntityPreviewVC.swift:734-756` and `PlaylistDetailVC.swift:314` keep their direct `librarySyncer.syncDown(playlist:)` call as the implementation detail — they just also fire a descriptor into the runner for status tracking.** We do *not* reroute those sites through the runner as a hard dependency; the runner is observability + coordination, not a mandatory gateway. If the runner is down (flag off, or initialization failure), lazy sync still works.

    Rationale: PR 19's job is to surface and coordinate, not to bottleneck the feature UX through a new queue.

### 3.8 Where PR 19's Settings status panel plugs in

- New file `Amperfy/SwiftUI/Settings/BackgroundTasksSection.swift`, a SwiftUI `Section` composed into the existing `LibrarySettingsView` (`Amperfy/SwiftUI/Settings/LibrarySettingsView.swift`).
- Binds to `BackgroundTaskStatusStore.shared` via `@ObservedObject` (or `@EnvironmentObject` if we hoist it). Three rows wired to `.albumScan`, `.playlistItemSync`, `.adjacencyCompute`.
- "Run now" rows call `BackgroundTaskRunner.shared.runNow(kind:)`.
- UI design is explicitly out of scope for this doc (designer pass after architecture sign-off per BACKLOG §19.3). This section names the plug-in point and nothing more.

---

## 4. Server-side seam

The `TaskExecutor` protocol is the seam. The runner/status/enqueue layer never looks inside it.

**Contract for a future `RemoteTaskExecutor`:**
- Accepts the same `TaskDescriptor` (already designed as a serializable value type).
- POSTs the descriptor to a server-side endpoint (`/api/v1/tasks`), receives a job ID.
- Streams progress events via SSE or long-poll (`/api/v1/tasks/{id}/events`), mapping server events onto the same `TaskEventSink` the runner hands in. From the runner's perspective, a remote executor is indistinguishable from a slow local one.
- On completion, the server writes results directly to a shared store (e.g. pushes adjacency pairs to the device's `TrackAdjacencySQLiteStore` via a blob download, or writes playlist items via a scoped sync endpoint).

**Why this is tractable for the three current workers:**
- **Adjacency** is the easiest win. `PlaylistDataProvider` and `ScoredRelationSink` already exist (PR 12 groundwork, see `TrackAdjacencyProtocols.swift`). A server impl would swap the Core-Data-backed provider for a server-side playlist index, and the sink would become a binary blob the server returns for the client to import into SQLite. No device-side graph computation needed.
- **Playlist item sync** — partially server-side today (server is authoritative for playlist contents). A future optimization: server batches all per-playlist fetches into a single bulk response instead of N round-trips. This is a `RemoteTaskExecutor` concern, invisible to the runner.
- **Album scan** — least amenable to server-side offload (the data already comes from the server; the "scan" is just "fetch songs for albums we haven't yet fetched"). A remote executor here mainly means "let the server decide which albums need refresh and stream them back", i.e. inverting the `getAlbumWithoutSyncedSongs()` query. Plausible but lowest priority.

**What we do NOT commit to in PR 19:** any network schema, any SSE vs long-poll choice, any server-side implementation. We only commit to `TaskDescriptor` being serializable and `TaskExecutor` being swappable. The future PR can redesign the wire format freely.

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

Each step ships on its own. Each step leaves the app working.

**Step 1 — Status store only (flag-gated, no runner yet).**
Add `BackgroundTaskStatus` enum and `BackgroundTaskStatusStore`. Instrument the three existing call sites to poke the store on start/success/failure. Wire the Settings panel to read from the store. Phase 2 stays disabled; its row shows `.disabled(reason: "Phase 2 off — in-playlist lookup triggers on tap")`. Ships the visible PR 19 feature end-to-end. Exactly the BACKLOG.md §19.3 shape.

**Step 2 — Introduce `TaskDescriptor` / `TaskExecutor` / `BackgroundTaskRunner` skeleton.**
Define the types, add `LocalTaskExecutor` with a stub registry. Do not wire anything to it yet. Unit tests for descriptor equality, queue serialization, status transitions. Zero behaviour change in the app.

**Step 3 — Migrate Phase 1 (album scan) behind `runnerEnabled` flag.**
Extract the Phase 1 body from `syncAlbumSongsInBackground()` into `AlbumScanWorker`. The existing `BackgroundLibrarySyncer.start()` entry point now calls `BackgroundTaskRunner.shared.enqueue(.albumScan(scope: .all, trigger: .scheduled))`. The old code path stays reachable behind `runnerEnabled = false` for rollback. Ship, watch metrics. One kind is now through the runner.

**Step 4 — Migrate adjacency.**
Extract `AppDelegate.computeTrackAdjacencyInBackground()` into `AdjacencyWorker`. Enqueue from the same launch point. Remove the `DispatchQueue.global` call. Status panel now reports adjacency live. Ship.

**Step 5 — Re-enable Phase 2 behind `phase2Enabled` flag (default OFF).**
Add `PlaylistSyncWorker` with per-playlist-batch context reset. Internal dogfood on Olivier's device with flag on. Measure peak memory vs Build 32. Do not enable for QA until profiled. Once clean, flip flag default to ON in a subsequent build.

**Step 6 — "Run now" triggers + lazy-path status tracking.**
Wire the Settings row buttons to `runNow(kind:)`. Instrument `EntityPreviewVC` and `PlaylistDetailVC` lazy-sync sites to fire status-tracking descriptors (but keep their direct `syncDown(playlist:)` calls untouched per §3.7).

**Step 7 — Cleanup.**
Delete the pre-runner code path behind `runnerEnabled`. Runner is the only way in. `BackgroundLibrarySyncer` shrinks to a thin compat shell or is renamed / folded into the runner module.

Steps 1, 3, 4, 5, 6 are each user-visible ship increments. Steps 2 and 7 are pure refactors.

---

## 7. Risks

1. **Phase 2 memory regression returns.** The batched-reset discipline in `PlaylistSyncWorker` is theory until profiled. *Mitigation:* Step 5 ships behind a default-OFF flag; Olivier validates on his ~2 GB-kill library before broader rollout. Add `MemoryReporter` checkpoints around every batch boundary, fail the task (not the app) if peak exceeds a budget.

2. **Runner introduces a new kind of bug — status drift.** Store says "running" forever because a worker crashed without emitting a terminal event. *Mitigation:* the runner — not the worker — owns the transition. A watchdog timer on each `running` state flips to `.failed("timeout")` after a per-kind ceiling (e.g. 15 min for album scan, 5 min for adjacency). Also: app-launch sweep that resets any `.running` entry from a prior session to `.failed("interrupted")`.

3. **Lazy-path + runner double-sync.** User taps "in playlist" while the background runner is also mid-sync on the same playlist. Two `syncDown(playlist:)` fire in parallel, Core Data conflicts. *Mitigation:* `PlaylistItemsSyncTracker.markInFlight(id)` gate — both paths consult it. This is a small extension to the existing tracker, not new infrastructure.

4. **Server-side seam underbakes.** We ship `TaskExecutor` as a protocol but the first remote executor reveals `TaskDescriptor` is missing fields (auth scope, server version, idempotency key). *Mitigation:* explicitly scope §4 as "seam exists, wire format TBD in future PR". The descriptor type is internal-only until a remote PR; we can grow it freely.

5. **Operation cancellation under app-backgrounding.** iOS suspends the app mid-Phase-1; existing `beginBackgroundTask` extension is in `BackgroundLibrarySyncer` today. If we refactor without carrying it through, Phase 1 starts dying silently at scenes/backgrounding. *Mitigation:* the runner owns the `UIApplication.beginBackgroundTask` lifecycle, not the workers. One place to get it right, checked in Step 3 against current behaviour.

---

## 8. Open questions for Olivier

1. **Should the runner live in `AmperfyKit` or in the app target?** BACKLOG §19.3 says `BackgroundTaskStatusStore` is UserDefaults-backed (kit-appropriate), but `UIApplication.beginBackgroundTask` is app-target-only. Proposal: runner **core** in AmperfyKit, **UIKit lifecycle bridge** in the app target, injected into the runner at launch. Confirm this split is acceptable.

2. **Do we want cross-account runner state or per-account?** Today `MetaManager` holds a per-account `backgroundLibrarySyncer`. If you switch accounts, does each account have its own task history, or is the runner a singleton with account-scoped descriptors? Proposal: singleton runner, each descriptor carries an `accountId`, status store keys by `(accountId, kind)`. Confirm.

3. **Phase 2 default state after re-enable.** Once `phase2Enabled` is proven stable, do we default it ON for all users, or keep it opt-in via Settings → Developer? Current implicit assumption: ON by default once safe. Confirm or redirect.

4. **"Run now" scope on `.playlistItemSync`.** Should the Settings row "Run now" button sync *all* unsynced playlists (potentially minutes of work), or only the N most recently touched? Proposal: all-unsynced, with a cancel button while running. Confirm.

5. **Adjacency auto-kick after Phase 2 completes.** Today's commented-out code enqueued an adjacency recompute right after playlist sync. That's probably right, but it means every Phase 2 run costs an adjacency run too. Acceptable, or should we gate adjacency recompute behind "N new playlists changed" threshold? Proposal: always kick, but use `computeIfNeeded()` not `computeFromScratch()` — since the SQLite store is append-accumulate, `isStale=true` + `computeIfNeeded` is safe and cheap when nothing actually changed. Confirm.
