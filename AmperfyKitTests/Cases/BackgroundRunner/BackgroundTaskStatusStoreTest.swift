//
//  BackgroundTaskStatusStoreTest.swift
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

// MARK: - BackgroundTaskStatusStoreTest

final class BackgroundTaskStatusStoreTest: XCTestCase {
  // MARK: - Helpers

  private var isolatedDefaultsSuiteName: String = ""
  private var isolatedDefaults: UserDefaults!

  override func setUp() {
    super.setUp()
    isolatedDefaultsSuiteName = "test.statusStore.\(UUID().uuidString)"
    isolatedDefaults = UserDefaults(suiteName: isolatedDefaultsSuiteName)!
  }

  override func tearDown() {
    isolatedDefaults.removePersistentDomain(forName: isolatedDefaultsSuiteName)
    isolatedDefaults = nil
    super.tearDown()
  }

  private func makeStore() -> BackgroundTaskStatusStore {
    BackgroundTaskStatusStore(defaults: isolatedDefaults)
  }

  // MARK: - Round-trip persistence

  func testRoundTripPersistence_completed() throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let expectedDuration: TimeInterval = 42.5

    let firstStore = makeStore()
    firstStore.transition(
      .albumScan,
      to: .completed(at: fixedDate, durationSeconds: expectedDuration)
    )

    // Allow the barrier write to complete before reading in a new store instance.
    let expectation = expectation(description: "barrier write flush")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
    wait(for: [expectation], timeout: 1)

    let secondStore = makeStore()
    let loadedStatus = secondStore.status(for: .albumScan)
    if case let .completed(loadedDate, loadedDuration) = loadedStatus {
      // Compare with 1 ms tolerance to survive ISO8601 round-trip rounding.
      XCTAssertEqual(
        loadedDate.timeIntervalSince1970,
        fixedDate.timeIntervalSince1970,
        accuracy: 0.001
      )
      XCTAssertEqual(loadedDuration, expectedDuration, accuracy: 0.001)
    } else {
      XCTFail("Expected .completed but got \(loadedStatus)")
    }
  }

  func testRoundTripPersistence_failed() throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_001)
    let expectedErrorMessage = "timeout"

    let firstStore = makeStore()
    firstStore.transition(
      .adjacencyCompute,
      to: .failed(at: fixedDate, errorMessage: expectedErrorMessage)
    )

    let expectation = expectation(description: "barrier write flush")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
    wait(for: [expectation], timeout: 1)

    let secondStore = makeStore()
    let loadedStatus = secondStore.status(for: .adjacencyCompute)
    if case let .failed(loadedDate, loadedMessage) = loadedStatus {
      XCTAssertEqual(
        loadedDate.timeIntervalSince1970,
        fixedDate.timeIntervalSince1970,
        accuracy: 0.001
      )
      XCTAssertEqual(loadedMessage, expectedErrorMessage)
    } else {
      XCTFail("Expected .failed but got \(loadedStatus)")
    }
  }

  func testRoundTripPersistence_disabled() throws {
    let expectedReason = "Phase 2 off"

    let firstStore = makeStore()
    firstStore.transition(.playlistItemSync, to: .disabled(reason: expectedReason))

    let expectation = expectation(description: "barrier write flush")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
    wait(for: [expectation], timeout: 1)

    let secondStore = makeStore()
    let loadedStatus = secondStore.status(for: .playlistItemSync)
    if case let .disabled(loadedReason) = loadedStatus {
      XCTAssertEqual(loadedReason, expectedReason)
    } else {
      XCTFail("Expected .disabled but got \(loadedStatus)")
    }
  }

  // MARK: - Transient states not persisted

  func testTransientRunning_isNotPersisted() throws {
    let firstStore = makeStore()
    firstStore.transition(.albumScan, to: .running(since: Date()))

    let expectation = expectation(description: "barrier write flush")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
    wait(for: [expectation], timeout: 1)

    let secondStore = makeStore()
    let loadedStatus = secondStore.status(for: .albumScan)
    if case .idle = loadedStatus {
      // Correct — transient .running was not persisted.
    } else {
      XCTFail("Expected .idle (transient not persisted) but got \(loadedStatus)")
    }
  }

  // MARK: - Transition sequences

  func testTransitionSequence_idleToRunningToCompleted() {
    let store = makeStore()
    XCTAssertEqual(store.status(for: .albumScan), .idle)

    store.transition(.albumScan, to: .running(since: Date()))
    let runningExpectation = expectation(description: "running transition")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { runningExpectation.fulfill() }
    wait(for: [runningExpectation], timeout: 1)
    if case .running = store.status(for: .albumScan) {
      // correct
    } else {
      XCTFail("Expected .running but got \(store.status(for: .albumScan))")
    }

    store.transition(.albumScan, to: .completed(at: Date(), durationSeconds: 5.0))
    let completedExpectation = expectation(description: "completed transition")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { completedExpectation.fulfill() }
    wait(for: [completedExpectation], timeout: 1)
    if case .completed = store.status(for: .albumScan) {
      // correct
    } else {
      XCTFail("Expected .completed but got \(store.status(for: .albumScan))")
    }
  }

  func testTransitionSequence_idleToRunningToFailed() {
    let store = makeStore()
    XCTAssertEqual(store.status(for: .adjacencyCompute), .idle)

    store.transition(.adjacencyCompute, to: .running(since: Date()))
    let runningExpectation = expectation(description: "running transition")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { runningExpectation.fulfill() }
    wait(for: [runningExpectation], timeout: 1)

    store.transition(.adjacencyCompute, to: .failed(at: Date(), errorMessage: "test error"))
    let failedExpectation = expectation(description: "failed transition")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { failedExpectation.fulfill() }
    wait(for: [failedExpectation], timeout: 1)
    if case .failed = store.status(for: .adjacencyCompute) {
      // correct
    } else {
      XCTFail("Expected .failed but got \(store.status(for: .adjacencyCompute))")
    }
  }

  // MARK: - Notification

  func testNotificationPostedOnTransition() {
    let store = makeStore()
    let notificationExpectation = expectation(
      forNotification: BackgroundTaskStatusStore.didChangeNotification,
      object: nil
    )
    store.transition(.albumScan, to: .completed(at: Date(), durationSeconds: 1.0))
    wait(for: [notificationExpectation], timeout: 2)
  }

  // MARK: - Combine publisher

  func testCombinePublisherEmitsOnTransition() {
    let store = makeStore()
    let publisherExpectation = expectation(description: "publisher emits")
    var cancellable: Any?

    cancellable = store.statusPublisher
      .dropFirst() // Skip the initial value
      .sink { statusDictionary in
        if case .completed = statusDictionary[.albumScan] {
          publisherExpectation.fulfill()
        }
      }
    store.transition(.albumScan, to: .completed(at: Date(), durationSeconds: 1.0))
    wait(for: [publisherExpectation], timeout: 2)
    _ = cancellable // Retain the subscription
  }
}
