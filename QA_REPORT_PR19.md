# QA Report — PR 19: Unified Background Task Runner

**Branch:** olivierMain
**Build:** 43
**Date:** 2026-04-17
**QA performed by:** QA sub-agent (Claude Sonnet 4.6)

---

## Step 1: Build + Test Results

### Build
```
xcodebuild -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
**Result: BUILD SUCCEEDED** (no errors, no warnings blocked the build)

### Tests
```
xcodebuild ... test -only-testing:AmperfyKitTests/BackgroundTaskStatusStoreTest
              -only-testing:AmperfyKitTests/BackgroundTaskRunnerTest
```
**Result: TEST SUCCEEDED**
- BackgroundTaskStatusStoreTest: 8/8 passed
- BackgroundTaskRunnerTest: 5/5 passed
- Total: **13/13 tests passed, 0 failures**

---

## Step 2: Static Code Verification — 16 QA Items

### Runner Infrastructure (AmperfyKit/BackgroundRunner/)

| # | File | Check | Verdict |
|---|------|-------|---------|
| 1 | `TaskKind.swift` | 3 cases: `albumScan`, `playlistItemSync`, `adjacencyCompute` | **PASS** |
| 2 | `TaskDescriptor.swift` | Value type (`struct`) with `kind`, `triggerReason`, `priority` | **PASS** |
| 3 | `BackgroundTaskWorker.swift` | Protocol with `kind: TaskKind` and `run(descriptor:context:) async throws` | **PASS** |
| 4 | `BackgroundTaskRunner.swift` | Serial `OperationQueue` (maxConcurrentOperationCount=1), worker registry with `NSLock`, watchdog per kind, `performLaunchSweep()` | **PASS** |
| 5 | `BackgroundTaskStatusStore.swift` | UserDefaults-backed, `CurrentValueSubject` Combine publisher, `DispatchQueue` reader-writer lock, `accessQueue` with `.concurrent` + `.barrier` writes | **PASS** |
| 6 | `BackgroundRunnerFeatureFlags.swift` | Only `phase2Enabled` present (default `false`); no `runnerEnabled` flag (correctly removed in 19e) | **PASS** |

### Workers

| # | File | Check | Verdict |
|---|------|-------|---------|
| 7 | `AlbumScanWorker.swift` | Phase 1 album scan logic extracted from `BackgroundLibrarySyncer`; checks `isCancelled` and `isOnlineMode` per-album; calls `context.reportProgress`; kind = `.albumScan` | **PASS** |
| 8 | `AdjacencyWorker.swift` | Wraps `DefaultTrackAdjacencyService.computeIfNeeded()` (or `.invalidate()` + `.computeFromScratch()` on `.invalidation` trigger); runs on background GCD queue via `withCheckedContinuation`; kind = `.adjacencyCompute` | **PASS** |
| 9 | `PlaylistSyncWorker.swift` | **CRITICAL — Build 30 memory fix.** `contextResetBatchSize = 5`. Per-5-playlists `mainStorage.context.reset()` is present at `resetMainContext()` (line 191). Reset is called at every batch boundary that is not the last item. Post-sync auto-enqueues `.adjacencyCompute` with `.invalidation` trigger. Kind = `.playlistItemSync` | **PASS** |

**Item 9 detail:** The `resetMainContext()` call is correctly wired:
```swift
private static let contextResetBatchSize = 5

let isBatchBoundary = batchStart > 0 && (batchStart + 1) % Self.contextResetBatchSize == 0
if isBatchBoundary, !isLastItem {
    await resetMainContext()
    ...
}
```
`resetMainContext()` calls `mainStorage.context.reset()` on the `@MainActor`. This is exactly the Build 30 fix.

### Wiring

| # | File | Check | Verdict |
|---|------|-------|---------|
| 10 | `BackgroundLibrarySyncer.swift` | Old direct Phase 1 loop is gone; `syncAlbumSongsInBackground()` now only calls `BackgroundTaskRunner.shared.enqueue(.albumScan)` and `.enqueue(.playlistItemSync)`; `stop()` calls `BackgroundTaskRunner.shared.cancelAll()` | **PASS** |
| 11 | `AppDelegate.swift` | No `computeTrackAdjacencyInBackground()` direct dispatch. `performLaunchSweep()` called at `didFinishLaunchingWithOptions`. `.adjacencyCompute` enqueued after `startManagerForNormalOperation()`. Phase 2 disabled-poke present (`BackgroundTaskStatusStore.shared.transition(.playlistItemSync, to: .disabled(...))`) when `!phase2Enabled` | **PASS** |
| 12 | `MetaManager.swift` | `registerRunnerWorkers()` present; registers `AlbumScanWorker`, `AdjacencyWorker`, and `PlaylistSyncWorker` via `BackgroundTaskRunner.shared.register(worker:)`; called from `startManagerForNormalOperation()` and the after-sync variant | **PASS** |
| 13 | `LibrarySettingsView.swift` | `BackgroundTasksSection()` instantiated at line 181 inside the settings view body | **PASS** |
| 14 | `BackgroundTasksSection.swift` | 3 rows: "Album Scan" (`.albumScan`), "Playlist Sync" (`.playlistItemSync`), "Track Adjacency" (`.adjacencyCompute`). Read-only — no buttons, no controls. Refreshes via `NotificationCenter` on `BackgroundTaskStatusStore.didChangeNotification` | **PASS** |

### Release

| # | File | Check | Verdict |
|---|------|-------|---------|
| 15 | `ReleaseNotes.swift` | Build 43 entry present (`id: 43`, `title: "Build 43 — Unified background task runner"`). Exactly 5 entries total (43, 41, 40, 39, 38) | **PASS** |
| 16 | `project.pbxproj` | `CURRENT_PROJECT_VERSION = 43` in all 5 build configuration entries | **PASS** |

---

## Summary

| Result | Count |
|--------|-------|
| PASS | 16 |
| FAIL | 0 |
| NEEDS_USER_EYES | 0 |

**16 / 16 PASS**

---

## Conclusion

PR 19 (Build 43, branch `olivierMain`) passes all QA checks.

- Build compiles cleanly with no errors
- All 13 unit tests pass (8 StatusStore + 5 Runner)
- All 16 static verification items pass
- **Critical item 9 (Build 30 memory fix):** `context.reset()` is correctly wired in `PlaylistSyncWorker` — every 5 playlists on a batch boundary that is not the last item. This is the exact pattern that prevents the ~2.1 GB Jetsam kill
- Pre-runner fallback paths (`computeTrackAdjacencyInBackground`, `queuePlaylistItemSyncs`, `runnerEnabled` flag) are fully absent from production code — only referenced in comments
- `phase2Enabled` defaults to `false` (OFF), so the playlist sync path is safely gated
- The runner, workers, status store, and Settings panel are all correctly wired end-to-end

**Ready to ship.**
