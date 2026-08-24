//
//  BackgroundTaskRunnerTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (PR 19a — Background task runner).
//  Copyright (c) 2026 Olivier Butler. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import AmperfyKit
import XCTest

// MARK: - BackgroundTaskRunnerTest

final class BackgroundTaskRunnerTest: XCTestCase {
  // MARK: - Setup helpers

  private var isolatedDefaultsSuiteName: String = ""
  private var isolatedDefaults: UserDefaults!
  private var testStatusStore: BackgroundTaskStatusStore!
  private var testFeatureFlags: BackgroundRunnerFeatureFlags!

  override func setUp() {
    super.setUp()
    isolatedDefaultsSuiteName = "test.runner.\(UUID().uuidString)"
    isolatedDefaults = UserDefaults(suiteName: isolatedDefaultsSuiteName)!
    testStatusStore = BackgroundTaskStatusStore(defaults: isolatedDefaults)
    testFeatureFlags = BackgroundRunnerFeatureFlags(defaults: isolatedDefaults)
  }

  override func tearDown() {
    isolatedDefaults.removePersistentDomain(forName: isolatedDefaultsSuiteName)
    isolatedDefaults = nil
    testStatusStore = nil
    testFeatureFlags = nil
    super.tearDown()
  }

  private func makeRunner(
    watchdogTimeoutProvider: (@Sendable (TaskKind) -> TimeInterval)? = nil
  )
    -> BackgroundTaskRunner {
    BackgroundTaskRunner(
      featureFlags: testFeatureFlags,
      statusStore: testStatusStore,
      watchdogTimeoutProvider: watchdogTimeoutProvider
    )
  }

  /// Blocks the caller until `condition` holds or `timeout` elapses.
  /// Returns whether the condition was met.
  @discardableResult
  private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
  )
    -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  private func waitForStatus(
    of kind: TaskKind,
    timeout: TimeInterval,
    matching predicate: @escaping (TaskStatus) -> Bool
  )
    -> TaskStatus {
    waitUntil(timeout: timeout) { predicate(self.testStatusStore.status(for: kind)) }
    return testStatusStore.status(for: kind)
  }

  // MARK: - Feature flag: phase 2 disabled

  func testEnqueue_whenPhase2Disabled_playlistSyncReturnsDisabled() {
    testFeatureFlags.phase2Enabled = false
    let runner = makeRunner()
    let descriptor = TaskDescriptor(kind: .playlistItemSync)

    let enqueueResult = runner.enqueue(descriptor)

    // Allow the async status write to complete.
    let settleExpectation = expectation(description: "status settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settleExpectation.fulfill() }
    wait(for: [settleExpectation], timeout: 1)

    XCTAssertFalse(enqueueResult, "enqueue should return false when phase 2 is disabled")
    if case .disabled = testStatusStore.status(for: .playlistItemSync) {
      // Correct.
    } else {
      XCTFail(
        "Expected .disabled for playlistItemSync but got \(testStatusStore.status(for: .playlistItemSync))"
      )
    }
  }

  // MARK: - Feature flag default values

  func testFeatureFlagDefaults_phase2EnabledByDefault() {
    // Phase 2 ships ON since PR 25 / build 44: a fresh install that never
    // touched the flag must default to enabled. Use a completely fresh
    // UserDefaults suite that has never been written to.
    let freshSuiteName = "test.defaults.\(UUID().uuidString)"
    let freshDefaults = UserDefaults(suiteName: freshSuiteName)!
    defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }

    let freshFlags = BackgroundRunnerFeatureFlags(defaults: freshDefaults)
    XCTAssertTrue(freshFlags.phase2Enabled, "phase2Enabled should default to true")
  }

  // MARK: - Enqueue with no registered worker

  func testEnqueue_withNoRegisteredWorker_completesWithFailed() {
    let runner = makeRunner()
    // No workers registered — runner should handle gracefully.
    let descriptor = TaskDescriptor(kind: .albumScan)

    let failureExpectation = expectation(description: "runner completes with failed")
    var cancellable: Any?
    cancellable = testStatusStore.statusPublisher
      .sink { statusDictionary in
        if case .failed = statusDictionary[.albumScan] {
          failureExpectation.fulfill()
        }
      }

    runner.enqueue(descriptor)
    wait(for: [failureExpectation], timeout: 5)
    _ = cancellable
  }

  // MARK: - Launch sweep

  func testLaunchSweep_clearsRunningStatusToFailed() {
    // Manually write a .running status by transitioning via the store.
    testStatusStore.transition(.albumScan, to: .running(since: Date()))
    testStatusStore.transition(.adjacencyCompute, to: .running(since: Date()))

    let settleExpectation = expectation(description: "status settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settleExpectation.fulfill() }
    wait(for: [settleExpectation], timeout: 1)

    let runner = makeRunner()
    runner.performLaunchSweep()

    let sweepExpectation = expectation(description: "sweep settles")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { sweepExpectation.fulfill() }
    wait(for: [sweepExpectation], timeout: 1)

    if case let .failed(_, errorMessage) = testStatusStore.status(for: .albumScan) {
      XCTAssertTrue(
        errorMessage.contains("interrupted"),
        "Error message should mention interruption"
      )
    } else {
      XCTFail(
        "Expected .failed for albumScan after launch sweep, got \(testStatusStore.status(for: .albumScan))"
      )
    }

    if case let .failed(_, errorMessage) = testStatusStore.status(for: .adjacencyCompute) {
      XCTAssertTrue(
        errorMessage.contains("interrupted"),
        "Error message should mention interruption"
      )
    } else {
      XCTFail("Expected .failed for adjacencyCompute after launch sweep")
    }
  }

  func testLaunchSweep_doesNotAffectCompletedStatus() {
    let completionDate = Date()
    testStatusStore.transition(
      .albumScan,
      to: .completed(at: completionDate, durationSeconds: 10.0)
    )

    let settleExpectation = expectation(description: "status settle")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settleExpectation.fulfill() }
    wait(for: [settleExpectation], timeout: 1)

    let runner = makeRunner()
    runner.performLaunchSweep()

    let sweepExpectation = expectation(description: "sweep settles")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { sweepExpectation.fulfill() }
    wait(for: [sweepExpectation], timeout: 1)

    if case .completed = testStatusStore.status(for: .albumScan) {
      // Correct — completed status should not be affected by launch sweep.
    } else {
      XCTFail(
        "Expected .completed to survive launch sweep, got \(testStatusStore.status(for: .albumScan))"
      )
    }
  }

  // MARK: - Watchdog is armed at start, not at enqueue

  /// The regression this guards: the watchdog used to be armed when a task was
  /// ENQUEUED, so a playlist sync sitting behind a multi-hour album scan on the
  /// serial queue burned its whole budget waiting and was cancelled before it
  /// ran a single line. Queue wait must not count against the budget.
  func testWatchdog_doesNotFireForTaskThatOnlyWaitedInQueue() {
    testFeatureFlags.phase2Enabled = true
    let runner = makeRunner { taskKind in
      taskKind == .playlistItemSync ? 0.4 : 60
    }

    let blockingWorker = StubBackgroundTaskWorker(kind: .albumScan, workDuration: 1.5)
    let quickWorker = StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 0)
    runner.register(worker: blockingWorker)
    runner.register(worker: quickWorker)

    XCTAssertTrue(runner.enqueue(TaskDescriptor(kind: .albumScan)))
    XCTAssertTrue(runner.enqueue(TaskDescriptor(kind: .playlistItemSync)))

    // The playlist sync waits ~1.5 s behind the album scan — far longer than its
    // 0.4 s budget — then runs to completion in well under it.
    let finalStatus = waitForStatus(of: .playlistItemSync, timeout: 10) { status in
      if case .completed = status { return true }
      if case .failed = status { return true }
      return false
    }

    if case .completed = finalStatus {
      // Correct.
    } else {
      XCTFail("Queue wait must not consume the budget, but got \(finalStatus)")
    }
    XCTAssertTrue(quickWorker.hasFinishedWork, "The worker must actually have run")
    XCTAssertFalse(
      quickWorker.hasObservedCancellation,
      "The watchdog must not have cancelled a task that only waited in queue"
    )
    runner.cancelAll()
  }

  /// The watchdog must still do its job once the task is genuinely running.
  ///
  /// Asserted on the `.failed("timeout")` transition rather than the final
  /// status: a worker that honours the cancel flag returns cleanly, and the
  /// operation then records `.completed` over the watchdog's `.failed`.
  func testWatchdog_stillFiresForTaskThatOverrunsAfterStarting() {
    testFeatureFlags.phase2Enabled = true
    let runner = makeRunner { _ in 0.3 }

    let overrunningWorker = StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 10)
    runner.register(worker: overrunningWorker)

    let didObserveTimeout = Atomic<Bool>(wrappedValue: false)
    let timeoutSubscription = testStatusStore.statusPublisher
      .sink { statusDictionary in
        if case let .failed(_, errorMessage) = statusDictionary[.playlistItemSync],
           errorMessage == "timeout" {
          didObserveTimeout.wrappedValue = true
        }
      }

    XCTAssertTrue(runner.enqueue(TaskDescriptor(kind: .playlistItemSync)))

    XCTAssertTrue(
      waitUntil(timeout: 10) { didObserveTimeout.wrappedValue },
      "The watchdog must time out a task that overruns its budget after starting"
    )
    XCTAssertTrue(
      waitUntil(timeout: 5) { overrunningWorker.hasObservedCancellation },
      "The watchdog must set the cancel flag the worker polls"
    )
    timeoutSubscription.cancel()
    runner.cancelAll()
  }

  // MARK: - Descriptor priority

  func testEnqueue_userInitiatedTaskGetsHigherQueuePriority() {
    testFeatureFlags.phase2Enabled = true
    let runner = makeRunner { _ in 60 }

    // A long-running album scan holds the serial queue so the tasks enqueued
    // behind it are still pending when we snapshot the queue.
    runner.register(worker: StubBackgroundTaskWorker(kind: .albumScan, workDuration: 3))
    runner.register(worker: StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 0))
    runner.register(worker: StubBackgroundTaskWorker(kind: .adjacencyCompute, workDuration: 0))

    runner.enqueue(TaskDescriptor(kind: .albumScan))
    runner.enqueue(TaskDescriptor(
      kind: .playlistItemSync,
      triggerReason: .userRequested,
      priority: .userInitiated
    ))
    runner.enqueue(TaskDescriptor(kind: .adjacencyCompute, triggerReason: .scheduled))

    let queuedTasks = runner.queuedTasksSnapshot
    let userInitiatedTask = queuedTasks.first { $0.kind == .playlistItemSync }
    let backgroundTask = queuedTasks.first { $0.kind == .adjacencyCompute }

    XCTAssertEqual(
      userInitiatedTask?.queuePriority,
      .veryHigh,
      "A user-initiated descriptor must jump ahead of scheduled background work"
    )
    XCTAssertEqual(backgroundTask?.queuePriority, .normal)
    runner.cancelAll()
  }

  // MARK: - Idempotent enqueue

  /// The app re-enqueues the playlist sync on every foreground. That must be a
  /// no-op while a sync is already in flight rather than stacking duplicate runs.
  func testEnqueue_secondEnqueueOfInFlightKindIsANoOp() {
    testFeatureFlags.phase2Enabled = true
    let runner = makeRunner { _ in 60 }
    runner.register(worker: StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 3))

    let firstEnqueueResult = runner.enqueue(TaskDescriptor(kind: .playlistItemSync))
    let secondEnqueueResult = runner.enqueue(TaskDescriptor(kind: .playlistItemSync))

    XCTAssertTrue(firstEnqueueResult)
    XCTAssertFalse(secondEnqueueResult, "A kind already in flight must not be enqueued twice")
    XCTAssertTrue(runner.isQueuedOrRunning(kind: .playlistItemSync))
    XCTAssertEqual(
      runner.queuedTasksSnapshot.filter { $0.kind == .playlistItemSync }.count,
      1,
      "Only one operation of the kind may sit on the queue"
    )
    runner.cancelAll()
  }

  /// Once a run has finished the kind is free again — the guard must not wedge
  /// the runner permanently.
  func testEnqueue_kindIsEnqueueableAgainAfterItCompletes() {
    testFeatureFlags.phase2Enabled = true
    let runner = makeRunner { _ in 60 }
    runner.register(worker: StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 0))

    XCTAssertTrue(runner.enqueue(TaskDescriptor(kind: .playlistItemSync)))
    XCTAssertTrue(
      waitUntil(timeout: 10) { !runner.isQueuedOrRunning(kind: .playlistItemSync) },
      "The in-flight claim must be released when the task finishes"
    )
    XCTAssertTrue(runner.enqueue(TaskDescriptor(kind: .playlistItemSync)))
    runner.cancelAll()
  }

  // MARK: - Registered worker lookup

  func testHasRegisteredWorker_reflectsRegistration() {
    let runner = makeRunner()
    XCTAssertFalse(runner.hasRegisteredWorker(for: .playlistItemSync))
    runner.register(worker: StubBackgroundTaskWorker(kind: .playlistItemSync, workDuration: 0))
    XCTAssertTrue(runner.hasRegisteredWorker(for: .playlistItemSync))
  }
}

// MARK: - StubBackgroundTaskWorker

/// Test worker that occupies the queue for `workDuration` seconds while polling
/// the cancel flag, so tests can observe both watchdog firing and queue waiting.
private final class StubBackgroundTaskWorker: BackgroundTaskWorker, @unchecked Sendable {
  let kind: TaskKind
  private let workDuration: TimeInterval
  private let startedFlag = Atomic<Bool>(wrappedValue: false)
  private let finishedFlag = Atomic<Bool>(wrappedValue: false)
  private let cancellationFlag = Atomic<Bool>(wrappedValue: false)

  init(kind: TaskKind, workDuration: TimeInterval) {
    self.kind = kind
    self.workDuration = workDuration
  }

  var hasStartedWork: Bool { startedFlag.wrappedValue }
  var hasFinishedWork: Bool { finishedFlag.wrappedValue }
  var hasObservedCancellation: Bool { cancellationFlag.wrappedValue }

  func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws {
    startedFlag.wrappedValue = true
    let workDeadline = Date().addingTimeInterval(workDuration)
    while Date() < workDeadline {
      if context.isCancelled.wrappedValue {
        cancellationFlag.wrappedValue = true
        return
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if context.isCancelled.wrappedValue {
      cancellationFlag.wrappedValue = true
      return
    }
    finishedFlag.wrappedValue = true
  }
}
