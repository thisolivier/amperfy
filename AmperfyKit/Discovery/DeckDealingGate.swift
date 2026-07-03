//
//  DeckDealingGate.swift
//  AmperfyKit
//
//  Extracted from AuditionDeckController (Discovery sprint D4 fix pass) so the
//  re-entrancy-guard mechanism itself — a plain Swift concurrency pattern with
//  no UIKit/app-target dependency — can be unit tested directly via
//  `@testable import AmperfyKit`, matching every other test in this suite,
//  rather than requiring `@testable import Amperfy` (which this project's
//  AmperfyKitTests target cannot currently link against as an "Application
//  Tests" bundle — no BUNDLE_LOADER wiring exists, and adding one destabilized
//  the whole test target rather than fixing just this).
//
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

import Foundation

// MARK: - DeckDealingOperationKind

/// Which kind of dealing operation currently owns a `DeckDealingGate`.
public enum DeckDealingOperationKind: Sendable, Equatable {
  case refresh
  case dealMore
}

// MARK: - DeckDealingGate

/// Serializes async "dealing" operations (Audition Deck's `refresh()`/`dealMore()`) that mutate
/// shared state and are unsafe to run concurrently with each other — the confirmed D4 Director
/// review bug this type exists to close: an unguarded `refresh()` could overwrite `candidates`
/// with a stale pre-await snapshot after a concurrent `dealMore()` had already appended to it,
/// silently dropping the appended cards.
///
/// Implemented as a FIFO continuation queue (a "baton pass" mutex), NOT a `while let inFlightTask
/// { await task.value }` polling loop — an earlier version of this type used that polling shape
/// and had a real, reproducible livelock: when the current holder's `await task.value` and a
/// waiter's own `await existingTask.value` on that same now-completed task both become runnable
/// on the same actor turn, nothing guarantees the holder's own cleanup (clearing the slot) runs
/// before the waiter re-checks the loop condition — the waiter can keep "winning" that race
/// indefinitely, re-awaiting an already-resolved task over and over without ever yielding real
/// progress, spinning the CPU. The FIFO-queue design below has exactly one suspension point per
/// call and hands off explicitly via a single `continuation.resume()` call from whichever holder
/// finishes to the next waiter in line, with no re-check loop to race.
///
/// One `DeckDealingGate` instance == one shared mutual-exclusion slot. A caller owning multiple
/// independently-guardable resources needs multiple gate instances.
@MainActor
public final class DeckDealingGate {
  private var inFlightKind: DeckDealingOperationKind?
  private var waiters: [CheckedContinuation<(), Never>] = []

  public init() {}

  /// Runs `operation` exclusively against any other `run` call currently in flight through this
  /// same gate — same kind or different kind.
  ///
  /// - If `ignoreIfSameKindInFlight` is `true` and an operation of the same `kind` is already
  ///   running RIGHT NOW (checked once, at call time — not re-checked after queueing), this call
  ///   returns immediately WITHOUT running `operation` at all (matches `dealMore()`'s "a duplicate
  ///   tap expresses no newer intent" semantics — see `AuditionDeckController+Dealing.swift`).
  /// - Otherwise (including always, for a *different*-kind collision), this call queues behind
  ///   whatever is currently in flight and runs once it's this call's turn. Queueing rather than
  ///   cancelling is deliberate: abandoning an in-flight operation mid-way risks applying its
  ///   caller's own follow-up logic (e.g. `refresh()`'s pinning) against half-updated state.
  ///
  /// Callers that need to read/snapshot shared mutable state as part of `operation` should do so
  /// *inside* the `operation` closure, not before calling `run` — the whole point of this gate is
  /// that state read before waiting can go stale while waiting.
  public func run(
    kind: DeckDealingOperationKind,
    ignoreIfSameKindInFlight: Bool,
    operation: @escaping () async -> ()
  ) async {
    if inFlightKind != nil {
      if ignoreIfSameKindInFlight, inFlightKind == kind { return }
      await withCheckedContinuation { (continuation: CheckedContinuation<(), Never>) in
        waiters.append(continuation)
      }
    }

    inFlightKind = kind
    await operation()
    inFlightKind = nil

    // Hand the baton to exactly the next waiter in line (not all of them) — resuming more than
    // one at once would let a second waiter's continuation run concurrently with the first's
    // `inFlightKind = kind` claim below, breaking mutual exclusion all over again.
    if !waiters.isEmpty {
      let next = waiters.removeFirst()
      next.resume()
    }
  }
}
