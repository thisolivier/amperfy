//
//  DeckDealingGateTest.swift
//  AmperfyKitTests
//
//  Proves the D4 Director review's confirmed re-entrancy bug (refresh()/dealMore() overlap
//  silently dropping candidates) is closed at the mechanism level. `AuditionDeckController` itself
//  lives in the `Amperfy` app target, which `AmperfyKitTests` cannot currently `@testable import`
//  (no BUNDLE_LOADER wiring — adding one destabilized the whole test target rather than fixing
//  just this), so the guard logic was extracted to `DeckDealingGate` in AmperfyKit instead,
//  specifically so this property could be tested directly.
//
//  Uses `XCTestExpectation`-based coordination throughout (not manual busy-poll loops) to match
//  this codebase's established pattern for async concurrency tests (see `NeedleDropLatencyTest`,
//  `NeedleDropSpritePlayerStopRaceTest`).
//

@testable import AmperfyKit
import XCTest

// MARK: - DeckDealingGateTest

@MainActor
final class DeckDealingGateTest: XCTestCase {
  /// Simulates the exact bug: a "refresh" operation starts and is still in flight when a
  /// "dealMore" operation starts. Pre-fix, `dealMore`'s effect would be silently overwritten by
  /// `refresh`'s later, stale-snapshotted write. Post-fix, the gate forces `dealMore` to wait for
  /// `refresh` to finish, so both operations' effects survive, in order.
  func testDealMoreWaitsForInFlightRefreshAndBothEffectsSurvive() async {
    let gate = DeckDealingGate()
    let log = LogBox()

    let refreshStarted = expectation(description: "refresh started")
    let refreshFinished = expectation(description: "refresh finished")
    let dealMoreFinished = expectation(description: "dealMore finished")

    Task {
      await gate.run(kind: .refresh, ignoreIfSameKindInFlight: false) {
        log.append("refresh-start")
        refreshStarted.fulfill()
        // Hold this operation open long enough for the assertions below (taken while it's still
        // running) to observe dealMore genuinely blocked, not just fast enough to race past it.
        try? await Task.sleep(nanoseconds: 200_000_000)
        log.append("refresh-end")
      }
      refreshFinished.fulfill()
    }

    await fulfillment(of: [refreshStarted], timeout: 5)

    Task {
      await gate.run(kind: .dealMore, ignoreIfSameKindInFlight: true) {
        log.append("dealMore-start")
        log.append("dealMore-end")
      }
      dealMoreFinished.fulfill()
    }

    await fulfillment(of: [refreshFinished, dealMoreFinished], timeout: 5)

    XCTAssertEqual(
      log.snapshot(), ["refresh-start", "refresh-end", "dealMore-start", "dealMore-end"],
      "both operations' effects must be present, in order — this is what 'candidates dropped' looked like pre-fix"
    )
  }

  /// A same-kind collision (two `dealMore()` calls overlapping) with `ignoreIfSameKindInFlight:
  /// true` must skip the second call's operation entirely, not queue it.
  func testSecondSameKindCallWithIgnoreFlagIsSkippedNotQueued() async {
    let gate = DeckDealingGate()
    let log = LogBox()

    let firstStarted = expectation(description: "first started")
    let firstFinished = expectation(description: "first finished")
    let secondReturned = expectation(description: "second returned")

    Task {
      await gate.run(kind: .dealMore, ignoreIfSameKindInFlight: true) {
        log.append("first")
        firstStarted.fulfill()
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
      firstFinished.fulfill()
    }

    await fulfillment(of: [firstStarted], timeout: 5)

    Task {
      await gate.run(kind: .dealMore, ignoreIfSameKindInFlight: true) {
        log.append("second-should-not-run")
      }
      secondReturned.fulfill()
    }

    // The second call should return quickly (skipped, not queued) — well before the first
    // operation's own 200ms artificial hold finishes.
    await fulfillment(of: [secondReturned], timeout: 1)
    XCTAssertEqual(
      log.snapshot(),
      ["first"],
      "a duplicate same-kind call must be skipped, not queued"
    )

    await fulfillment(of: [firstFinished], timeout: 5)
    XCTAssertEqual(
      log.snapshot(),
      ["first"],
      "the skipped call must never run, even after the first finishes"
    )
  }

  /// A same-kind collision with `ignoreIfSameKindInFlight: false` (refresh()'s own semantics)
  /// DOES queue and eventually run the second call, unlike the dealMore case above.
  func testSecondSameKindCallWithoutIgnoreFlagWaitsThenRuns() async {
    let gate = DeckDealingGate()
    let log = LogBox()

    let firstStarted = expectation(description: "first started")
    let bothFinished = expectation(description: "both finished")
    bothFinished.expectedFulfillmentCount = 2

    Task {
      await gate.run(kind: .refresh, ignoreIfSameKindInFlight: false) {
        log.append("first-start")
        firstStarted.fulfill()
        try? await Task.sleep(nanoseconds: 200_000_000)
        log.append("first-end")
      }
      bothFinished.fulfill()
    }

    await fulfillment(of: [firstStarted], timeout: 5)

    Task {
      await gate.run(kind: .refresh, ignoreIfSameKindInFlight: false) {
        log.append("second-ran")
      }
      bothFinished.fulfill()
    }

    await fulfillment(of: [bothFinished], timeout: 5)
    XCTAssertEqual(log.snapshot(), ["first-start", "first-end", "second-ran"])
  }
}

// MARK: - LogBox

/// Test-only ordered-event log. Plain `NSLock`-guarded (not an actor) so it can be appended to
/// from `DeckDealingGate`'s internally-spawned `Task`s and read back synchronously from this
/// test's own (sync) assertions without an extra actor-hop dance.
private final class LogBox: @unchecked Sendable {
  private var events: [String] = []
  private let lock = NSLock()

  func append(_ event: String) {
    lock.withLock { events.append(event) }
  }

  func snapshot() -> [String] {
    lock.withLock { events }
  }
}
