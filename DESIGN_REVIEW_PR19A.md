# PR 19a — Runner Skeleton + Status Store + Status Panel: Implementation Brief

Status: DESIGN REVIEW
Author: designer agent, 2026-04-16
Scope: implementation brief for the implementer — covers every new file, every modified file, and QA acceptance criteria.

References:
- `ARCH_PROPOSAL_PR19.md` sections 3, 9 (PR 19a scope)
- `BACKLOG.md` PR 19 entries
- `BackgroundLibrarySyncer.swift` — existing album scan infrastructure
- `AppDelegate.swift` — `computeTrackAdjacencyInBackground()` call site
- `LibrarySettingsView.swift` — where the status panel plugs in

---

## 1. Runner Infrastructure (AmperfyKit target)

All new types live under `AmperfyKit/BackgroundRunner/`. Create this directory.

### 1.1 `TaskKind.swift`

```swift
public enum TaskKind: String, CaseIterable, Codable, Sendable {
  case albumScan
  case playlistItemSync
  case adjacencyCompute
}
```

Uses `String` raw value so UserDefaults keys are human-readable. `CaseIterable` for the status panel iteration. `Codable` for store persistence.

### 1.2 `TaskDescriptor.swift`

Simple value type. No serialization for wire transport per Olivier's refined direction.

```swift
public struct TaskDescriptor: Sendable {
  public let kind: TaskKind
  public let triggerReason: TriggerReason
  public let priority: TaskPriority

  public enum TriggerReason: String, Sendable {
    case scheduled
    case userRequested
    case invalidation
  }

  public enum TaskPriority: Int, Comparable, Sendable {
    case background = 0
    case userInitiated = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }
}
```

Provide a convenience initializer: `TaskDescriptor(kind:triggerReason:priority:)` with `priority` defaulting to `.background` and `triggerReason` defaulting to `.scheduled`.

### 1.3 `BackgroundTaskWorker.swift`

Protocol for future workers (PR 19b/c/d). No workers are registered in PR 19a.

```swift
public protocol BackgroundTaskWorker: Sendable {
  var kind: TaskKind { get }

  /// Called by the runner. Must check `context.isCancelled` periodically.
  func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws
}
```

Keep it minimal — no `memoryProfile` or `cooperatesWith` yet. Those are PR 19b+ concerns when there are real workers to profile. Add them later rather than shipping dead protocol requirements.

### 1.4 `TaskRunContext.swift`

What the runner provides to workers.

```swift
public final class TaskRunContext: Sendable {
  public let isCancelled: Atomic<Bool>
  public let reportProgress: @Sendable (TaskProgress) -> Void

  public init(
    isCancelled: Atomic<Bool>,
    reportProgress: @escaping @Sendable (TaskProgress) -> Void
  ) {
    self.isCancelled = isCancelled
    self.reportProgress = reportProgress
  }
}

public enum TaskProgress: Sendable {
  case started
  case progress(done: Int, total: Int)
  case checkpoint(label: String)
}
```

Core Data context and memory checkpoint will be added in PR 19b when the first real worker needs them. For the skeleton, `isCancelled` + `reportProgress` are sufficient to prove the protocol and write tests.

### 1.5 `BackgroundTaskRunner.swift`

Singleton. Serial `OperationQueue`-backed. Owns task lifecycle.

**Public interface:**

```swift
public final class BackgroundTaskRunner: @unchecked Sendable {
  public static let shared = BackgroundTaskRunner()

  /// Register a worker for a given kind. Call at app startup before enqueue.
  public func register(worker: BackgroundTaskWorker)

  /// Enqueue a task. Respects feature flags — returns false if runner is disabled.
  @discardableResult
  public func enqueue(_ descriptor: TaskDescriptor) -> Bool

  /// Cancel all running/queued tasks.
  public func cancelAll()

  /// Call on every app launch. Sweeps any `.running` status entries
  /// left over from a prior session and transitions them to `.failed("interrupted")`.
  public func performLaunchSweep()
}
```

**Internal details:**

- Private `OperationQueue` with `maxConcurrentOperationCount = 1`.
- Worker registry: `private var workers: [TaskKind: BackgroundTaskWorker] = [:]`
- `enqueue(_:)` checks `BackgroundRunnerFeatureFlags.shared.runnerEnabled`. If false, returns false and does nothing.
- `enqueue(_:)` checks `phase2Enabled` for `.playlistItemSync` kind; if disabled, pokes status store with `.disabled(reason:)` and returns false.
- Each enqueued task wraps in an `Operation` subclass (reuse `AsyncOperation` from `AmperfyKit/Common/AsyncOperation.swift`) that:
  1. Sets status to `.running(since: Date())` via `BackgroundTaskStatusStore`.
  2. Creates a `TaskRunContext` with a cancel flag and progress callback.
  3. Calls `worker.run(descriptor:context:)`.
  4. On success: sets status to `.completed(at: Date(), durationSeconds: elapsed)`.
  5. On error: sets status to `.failed(at: Date(), errorMessage: error.localizedDescription)`.
  6. Watchdog: schedule a `DispatchWorkItem` at enqueue time per kind. Timeout ceilings: 15 min for `.albumScan`, 5 min for `.adjacencyCompute`, 10 min for `.playlistItemSync`. If the watchdog fires, cancel the operation and set `.failed(at:errorMessage: "timeout")`.
- `performLaunchSweep()`: reads all `TaskKind.allCases` from the status store. Any entry with `.running` status is transitioned to `.failed(at: Date(), errorMessage: "interrupted — app was terminated")`.
- `cancelAll()`: calls `taskQueue.cancelAllOperations()`, sets all `.running`/`.queued` entries to `.failed`.

**Note:** `beginBackgroundTask` integration is deferred to PR 19b when there is a real worker that needs continued execution during app backgrounding. The skeleton does not need it.

### 1.6 `BackgroundTaskStatusStore.swift`

UserDefaults-backed for terminal states. Combine-published. Follows the `ThemeStore` / `StylingPresetStore` pattern: singleton, private `UserDefaults` reference, `Notification.Name` for cross-layer observation.

**Key scheme:** `"amperfy.fork.runner.status.<taskKind.rawValue>"` — stores a JSON-encoded `PersistedTaskStatus` struct.

**Status enum:**

```swift
public enum TaskStatus: Equatable, Sendable {
  case idle
  case queued(since: Date)
  case running(since: Date)
  case completed(at: Date, durationSeconds: TimeInterval)
  case failed(at: Date, errorMessage: String)
  case disabled(reason: String)
}
```

**Persisted shape** (only terminal states are persisted):

```swift
struct PersistedTaskStatus: Codable {
  enum Kind: String, Codable {
    case idle, completed, failed, disabled
  }
  let kind: Kind
  let timestamp: Date?
  let durationSeconds: TimeInterval?
  let message: String?
}
```

Transient states (`.queued`, `.running`) are held in-memory only via a `[TaskKind: TaskStatus]` dictionary. On app launch, the store loads persisted terminals from UserDefaults for all three kinds. Anything not persisted defaults to `.idle`.

**Combine publishing:**

Use `CurrentValueSubject<[TaskKind: TaskStatus], Never>` as the backing publisher. Expose:

```swift
public var statusPublisher: AnyPublisher<[TaskKind: TaskStatus], Never>
public func status(for kind: TaskKind) -> TaskStatus
```

Also post `Notification.Name("amperfy.fork.runner.status.didChange")` on every transition, for any UIKit observers that prefer NotificationCenter over Combine.

**Write API** (called by the runner, not by workers):

```swift
public func transition(_ kind: TaskKind, to newStatus: TaskStatus)
```

This method:
1. Updates the in-memory dictionary.
2. If the new status is a terminal (`.completed`, `.failed`, `.disabled`, `.idle`), persists to UserDefaults.
3. Sends through the `CurrentValueSubject`.
4. Posts the notification.

**Init with UserDefaults DI** (like `ThemeStore` and `StylingPresetStore`):

```swift
public init(defaults: UserDefaults = .standard)
```

This enables unit testing with an isolated `UserDefaults(suiteName:)`.

### 1.7 `BackgroundRunnerFeatureFlags.swift`

```swift
public final class BackgroundRunnerFeatureFlags: @unchecked Sendable {
  public static let shared = BackgroundRunnerFeatureFlags()

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private enum Key {
    static let runnerEnabled = "amperfy.fork.runner.enabled"
    static let phase2Enabled = "amperfy.fork.runner.phase2Enabled"
  }

  /// Kill-switch. Default ON. If false, runner.enqueue() is a no-op
  /// and existing code paths run unmodified.
  public var runnerEnabled: Bool {
    get {
      // Default true: if the key has never been written, return true
      defaults.object(forKey: Key.runnerEnabled) == nil
        ? true
        : defaults.bool(forKey: Key.runnerEnabled)
    }
    set { defaults.set(newValue, forKey: Key.runnerEnabled) }
  }

  /// Phase 2 (playlist item sync). Default OFF.
  public var phase2Enabled: Bool {
    get { defaults.bool(forKey: Key.phase2Enabled) }
    set { defaults.set(newValue, forKey: Key.phase2Enabled) }
  }
}
```

The `runnerEnabled` default-true pattern uses `object(forKey:) == nil` because `bool(forKey:)` returns `false` for missing keys. This matches how other feature flags in the codebase handle "default true" semantics.

---

## 2. Settings -> Library Status Panel (App Target)

### 2.1 `BackgroundTasksSection.swift`

New file at `Amperfy/SwiftUI/Settings/BackgroundTasksSection.swift`.

A SwiftUI `Section` that composes into `LibrarySettingsView.body`.

**Structure:**

```swift
struct BackgroundTasksSection: View {
  @State private var statuses: [TaskKind: TaskStatus] = [:]

  var body: some View {
    SettingsSection(content: {
      taskRow(label: "Album Scan", kind: .albumScan)
      taskRow(label: "Playlist Sync", kind: .playlistItemSync)
      taskRow(label: "Track Adjacency", kind: .adjacencyCompute)
    }, header: "Background Tasks")
  }
}
```

**Each row shows:**
- Status icon: use SF Symbols. `checkmark.circle.fill` (green) for `.completed`, `xmark.circle.fill` (red) for `.failed`, `clock.fill` (gray) for `.idle`, `arrow.triangle.2.circlepath` (blue) for `.running`/`.queued`, `minus.circle.fill` (gray) for `.disabled`.
- Label text (e.g. "Album Scan")
- Detail text: depends on status:
  - `.completed(at, durationSeconds)` — "Completed \(relativeTime(at)) (\(formattedDuration(durationSeconds)))"
  - `.failed(at, errorMessage)` — "Failed: \(errorMessage)"
  - `.running(since)` — "Running..."
  - `.queued(since)` — "Queued"
  - `.idle` — "Not yet run"
  - `.disabled(reason)` — "Disabled"

**Relative time formatting:** Use `RelativeDateTimeFormatter` with `.abbreviated` style. Shows "2 min. ago", "1 hr. ago", etc.

**Duration formatting:** Show as "Xs" for under 60s, "Xm Ys" for longer. Simple string formatting, no need for `DateComponentsFormatter`.

**Combine subscription:** Use `.onReceive(statusStorePublisher)` to update the `@State` dictionary. The publisher comes from `BackgroundTaskStatusStore.shared.statusPublisher`. Alternatively, use `.onAppear` to load initial state and the `Notification.Name` via `.onReceive(NotificationCenter.default.publisher(for:))` to refresh — this matches the timer-based pattern in `LibrarySettingsView` and avoids needing to import Combine in the SwiftUI layer.

Use the Notification approach to match existing codebase patterns (the timer `.onReceive` in `LibrarySettingsView`).

### 2.2 Composing into `LibrarySettingsView`

Insert `BackgroundTasksSection()` between the "Background song sync" section and the "Cache" section in `LibrarySettingsView.body`. This is a natural position — background task status sits alongside the existing background sync progress display.

---

## 3. Instrumentation of Existing Call Sites (No Migration)

PR 19a does NOT move compute behind the runner. It instruments existing call sites to poke the status store so the panel has live data.

### 3.1 `BackgroundLibrarySyncer.swift` — Album Scan

Modify `syncAlbumSongsInBackground()`:

- At entry (line ~109, after `os_log("start"...)`): call `BackgroundTaskStatusStore.shared.transition(.albumScan, to: .running(since: Date()))`.
- Record `let albumScanStartTime = Date()` at the same point.
- In `addOperationsEndMessage()`, inside the barrier block: call `BackgroundTaskStatusStore.shared.transition(.albumScan, to: .completed(at: Date(), durationSeconds: Date().timeIntervalSince(albumScanStartTime)))`.
- If the `do/catch` in the sync loop catches and the entire scan effectively fails, also poke `.failed`. However, the current design logs individual album errors but continues — so the scan as a whole succeeds. Keep the `.completed` transition in the barrier block as the terminal state.

Store the `albumScanStartTime` as a property on `BackgroundLibrarySyncer` (use `Atomic<Date?>` for thread safety, matching the existing `isRunning` pattern).

### 3.2 `AppDelegate.swift` — Adjacency Compute

Modify `computeTrackAdjacencyInBackground()`:

```swift
private func computeTrackAdjacencyInBackground() {
  BackgroundTaskStatusStore.shared.transition(.adjacencyCompute, to: .running(since: Date()))
  let adjacencyStartTime = Date()
  DispatchQueue.global(qos: .utility).async {
    DefaultTrackAdjacencyService.shared.computeIfNeeded()
    let elapsed = Date().timeIntervalSince(adjacencyStartTime)
    BackgroundTaskStatusStore.shared.transition(
      .adjacencyCompute,
      to: .completed(at: Date(), durationSeconds: elapsed)
    )
  }
}
```

Note: `computeIfNeeded()` can return early (store already has data, `staleFlag` is false). In that case the duration will be near-zero, which is fine — it reflects the truth.

### 3.3 Playlist Item Sync — Disabled

On app launch (in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, after the existing adjacency block), add:

```swift
if !BackgroundRunnerFeatureFlags.shared.phase2Enabled {
  BackgroundTaskStatusStore.shared.transition(
    .playlistItemSync,
    to: .disabled(reason: "Phase 2 disabled")
  )
}
```

This ensures the status panel shows "Disabled" for playlist sync from the first launch.

### 3.4 Kill-Switch Behavior

If `runnerEnabled` is set to `false`, the existing code paths run unmodified (they already do — we have not migrated anything). The instrumentation above still runs because it is inline in the existing code, not gated by `runnerEnabled`.

However, the task requirements say: "if `runnerEnabled = false`, status panel shows 'Disabled' for all." To implement this, add to the `BackgroundTasksSection` view: if `!BackgroundRunnerFeatureFlags.shared.runnerEnabled`, override all three rows to show `.disabled(reason: "Runner disabled")` regardless of store contents. This is a UI-layer override, not a store mutation.

### 3.5 Launch Sweep

In `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, early (before `startManagerForNormalOperation()`):

```swift
BackgroundTaskRunner.shared.performLaunchSweep()
```

This sweeps any `.running` entries left from a prior terminated session to `.failed("interrupted")`.

---

## 4. QA Acceptance Criteria

1. **Panel visible:** Settings -> Library shows a "Background Tasks" section with three rows: Album Scan, Playlist Sync, Track Adjacency.

2. **Fresh install — initial state:** On a fresh install (or after clearing UserDefaults), Album Scan shows "Not yet run" with a gray clock icon. Track Adjacency shows "Not yet run" with a gray clock icon. Playlist Sync shows "Disabled" with a gray minus icon.

3. **Album scan status updates:** After the app launches and background library sync runs, the Album Scan row transitions to show a green checkmark with "Completed X ago (Ys)" where X is the relative time and Y is the duration in seconds.

4. **Adjacency status updates:** After the app launches and adjacency compute runs, the Track Adjacency row transitions to show a green checkmark with "Completed X ago (Ys)".

5. **Adjacency skip (data exists):** If adjacency data already exists (not stale), `computeIfNeeded()` returns immediately. The row should still show "Completed" with a near-zero duration. This is correct behavior.

6. **Playlist sync disabled:** The Playlist Sync row shows "Disabled" with a gray minus icon at all times (Phase 2 is off).

7. **Status survives app relaunch:** Force-quit the app after album scan and adjacency have completed. Relaunch. The status panel should show the previously completed states with correct "last synced" timestamps (persisted via UserDefaults). Verify the relative time updates (e.g., "5 min. ago" becomes "6 min. ago").

8. **Duration display:** Album scan duration is non-trivial (several seconds on a library with unsynced albums). Verify format: "Xs" for under 60 seconds, "Xm Ys" for longer.

9. **Relative time display:** Verify the "ago" text uses iOS `RelativeDateTimeFormatter` style: "2 min. ago", "1 hr. ago", "yesterday", etc.

10. **Launch sweep — interrupted recovery:** Manually write a `.running` status to UserDefaults (via debug or test), then launch the app. The status should show as "Failed: interrupted — app was terminated" with a red icon.

11. **Kill-switch — all disabled:** Set `runnerEnabled = false` in UserDefaults (key `amperfy.fork.runner.enabled`). Launch the app. All three rows in the status panel should show "Disabled" regardless of any previously stored status.

12. **Kill-switch — existing code paths unaffected:** With `runnerEnabled = false`, verify the app still performs background library sync (album scan) and adjacency compute normally — only the status panel display changes.

13. **No run/cancel controls:** The status panel is strictly read-only. No buttons, no toggles, no swipe actions.

14. **Visual consistency:** The "Background Tasks" section matches the visual weight and spacing of the adjacent "Background song sync" and "Cache" sections. Uses the same `SettingsSection` / `SettingsRow` components.

---

## 5. File Inventory

### New Files

| File | Target | Purpose |
|------|--------|---------|
| `AmperfyKit/BackgroundRunner/TaskKind.swift` | AmperfyKit | `TaskKind` enum |
| `AmperfyKit/BackgroundRunner/TaskDescriptor.swift` | AmperfyKit | `TaskDescriptor` value type |
| `AmperfyKit/BackgroundRunner/BackgroundTaskWorker.swift` | AmperfyKit | Worker protocol + `TaskRunContext` + `TaskProgress` |
| `AmperfyKit/BackgroundRunner/BackgroundTaskRunner.swift` | AmperfyKit | Singleton runner with serial queue, launch sweep, watchdog |
| `AmperfyKit/BackgroundRunner/BackgroundTaskStatusStore.swift` | AmperfyKit | UserDefaults-backed status store with Combine publisher |
| `AmperfyKit/BackgroundRunner/BackgroundRunnerFeatureFlags.swift` | AmperfyKit | `runnerEnabled` + `phase2Enabled` flags |
| `Amperfy/SwiftUI/Settings/BackgroundTasksSection.swift` | Amperfy | SwiftUI Section for the Settings -> Library status panel |
| `AmperfyKitTests/Cases/BackgroundRunner/BackgroundTaskStatusStoreTest.swift` | AmperfyKitTests | Unit tests for the status store |
| `AmperfyKitTests/Cases/BackgroundRunner/BackgroundTaskRunnerTest.swift` | AmperfyKitTests | Unit tests for runner launch sweep and feature flag gating |

### Modified Files

| File | Changes |
|------|---------|
| `AmperfyKit/Api/BackgroundLibrarySyncer.swift` | Add `albumScanStartTime` property. Instrument `syncAlbumSongsInBackground()` entry with `.running` transition. Instrument `addOperationsEndMessage()` barrier with `.completed` transition. ~10 lines added. |
| `Amperfy/AppDelegate.swift` | Instrument `computeTrackAdjacencyInBackground()` with `.running`/`.completed` transitions (~6 lines). Add `.disabled` poke for playlist sync after adjacency block (~4 lines). Add `BackgroundTaskRunner.shared.performLaunchSweep()` call before `startManagerForNormalOperation()` (~1 line). |
| `Amperfy/SwiftUI/Settings/LibrarySettingsView.swift` | Insert `BackgroundTasksSection()` between the "Background song sync" section and the "Cache" section (~1 line). |
| `Amperfy.xcodeproj/project.pbxproj` | Add all new files to their respective targets. |

---

## 6. Unit Tests

All tests go in `AmperfyKitTests/Cases/BackgroundRunner/`.

### 6.1 `BackgroundTaskStatusStoreTest.swift`

Use an isolated `UserDefaults(suiteName: "test.statusStore.\(UUID().uuidString)")` for each test. Tear down with `removePersistentDomain(forName:)` in `tearDown`.

**Tests:**

1. **Round-trip persistence — completed:** Write `.completed(at: fixedDate, durationSeconds: 42.5)` for `.albumScan`. Create a new store instance with the same `UserDefaults`. Read back `.albumScan`. Assert status matches: timestamp, duration.

2. **Round-trip persistence — failed:** Write `.failed(at: fixedDate, errorMessage: "timeout")` for `.adjacencyCompute`. New store instance. Assert round-trip.

3. **Round-trip persistence — disabled:** Write `.disabled(reason: "Phase 2 off")` for `.playlistItemSync`. New store instance. Assert round-trip.

4. **Transient states not persisted:** Write `.running(since: Date())` for `.albumScan`. Create a new store instance. Assert status is `.idle` (transient was not persisted; new instance defaults to idle).

5. **Transition: idle -> running -> completed:** Assert initial is `.idle`. Transition to `.running`. Assert `.running`. Transition to `.completed`. Assert `.completed`.

6. **Transition: idle -> running -> failed:** Same pattern, terminal is `.failed`.

7. **Launch sweep — running to failed:** Write `.running` in-memory for `.albumScan` and `.adjacencyCompute`. Call the runner's `performLaunchSweep()` (or simulate by reading the store and checking the sweep logic). Assert both are now `.failed` with "interrupted" message.

8. **Launch sweep — completed not affected:** Write `.completed` for `.albumScan`. Perform launch sweep. Assert still `.completed`.

9. **Notification posted on transition:** Subscribe to the notification. Transition a status. Assert notification received.

10. **Combine publisher emits on transition:** Subscribe to `statusPublisher`. Transition `.albumScan` to `.completed`. Assert the published dictionary contains the new value.

### 6.2 `BackgroundTaskRunnerTest.swift`

1. **Feature flag — runner disabled:** Set `runnerEnabled = false` on a test `BackgroundRunnerFeatureFlags`. Call `enqueue(.albumScan)`. Assert returns `false`. Assert status store was not poked with `.running`.

2. **Feature flag — phase2 disabled:** With `runnerEnabled = true`, `phase2Enabled = false`. Enqueue `.playlistItemSync`. Assert returns `false`. Assert status store shows `.disabled` for `.playlistItemSync`.

3. **Feature flag — reads default values:** Fresh `UserDefaults`. Assert `runnerEnabled == true`. Assert `phase2Enabled == false`.

4. **Enqueue with no registered worker:** Enqueue `.albumScan` when no worker is registered for that kind. Assert the operation completes (no crash) and status transitions to `.failed` with a "no worker registered" message. This proves the skeleton is safe even without workers.

---

## Design Notes for Implementer

- **Target membership:** All `AmperfyKit/BackgroundRunner/` files go in the `AmperfyKit` framework target. The `BackgroundTasksSection.swift` goes in the `Amperfy` app target. Tests go in `AmperfyKitTests`.
- **No `import Combine` in the SwiftUI view.** Use `NotificationCenter.default.publisher(for:)` via `.onReceive` — this is available through SwiftUI's built-in Combine integration without an explicit import.
- **Thread safety for `BackgroundTaskStatusStore`:** The in-memory `[TaskKind: TaskStatus]` dictionary must be protected. Use a `DispatchQueue` (serial) or `NSLock`. The `transition(_:to:)` method is called from background threads (runner operations) and read from the main thread (SwiftUI). The Combine `CurrentValueSubject` handles its own thread safety for sends, but the dictionary read in `status(for:)` needs explicit protection.
- **Do not add the runner to `MetaManager` or `AmperKit` dependency graph yet.** The runner is a standalone singleton in PR 19a. Integration with the manager lifecycle happens in PR 19b when the first worker is migrated.
- **Xcode project file:** When adding the new directory `AmperfyKit/BackgroundRunner/`, create a corresponding group in the Xcode project. Add each `.swift` file to the `AmperfyKit` target's Compile Sources.
