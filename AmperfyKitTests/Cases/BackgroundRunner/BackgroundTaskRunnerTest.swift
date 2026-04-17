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

  private func makeRunner() -> BackgroundTaskRunner {
    BackgroundTaskRunner(featureFlags: testFeatureFlags, statusStore: testStatusStore)
  }

  // MARK: - Feature flag: runner disabled

  func testEnqueue_whenRunnerDisabled_returnsFalseAndDoesNotPoke() {
    testFeatureFlags.runnerEnabled = false
    let runner = makeRunner()
    let descriptor = TaskDescriptor(kind: .albumScan)

    let enqueueResult = runner.enqueue(descriptor)

    XCTAssertFalse(enqueueResult, "enqueue should return false when runner is disabled")
    XCTAssertEqual(
      testStatusStore.status(for: .albumScan),
      .idle,
      "Status store should not be poked when runner is disabled"
    )
  }

  // MARK: - Feature flag: phase 2 disabled

  func testEnqueue_whenPhase2Disabled_playlistSyncReturnsDisabled() {
    testFeatureFlags.runnerEnabled = true
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

  func testFeatureFlagDefaults_runnerEnabledAndPhase2Disabled() {
    // Use a completely fresh UserDefaults suite that has never been written to.
    let freshSuiteName = "test.defaults.\(UUID().uuidString)"
    let freshDefaults = UserDefaults(suiteName: freshSuiteName)!
    defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }

    let freshFlags = BackgroundRunnerFeatureFlags(defaults: freshDefaults)
    XCTAssertTrue(freshFlags.runnerEnabled, "runnerEnabled should default to true")
    XCTAssertFalse(freshFlags.phase2Enabled, "phase2Enabled should default to false")
  }

  // MARK: - Enqueue with no registered worker

  func testEnqueue_withNoRegisteredWorker_completesWithFailed() {
    testFeatureFlags.runnerEnabled = true
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
}
