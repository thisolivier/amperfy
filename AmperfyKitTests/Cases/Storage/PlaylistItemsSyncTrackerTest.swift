//
//  PlaylistItemsSyncTrackerTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (Hotfix — playlist item sync completeness).
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

/// Unit tests for `PlaylistItemsSyncTracker` count-mismatch invalidation.
/// The tracker must re-sync a playlist whose server-reported `remoteSongCount`
/// diverges from the number of items stored locally (edited-after-sync), so
/// that reverse-membership lookups don't silently return stale/incomplete data.
class PlaylistItemsSyncTrackerTest: XCTestCase {
  private var defaults: UserDefaults!
  private var tracker: PlaylistItemsSyncTracker!
  private let suiteName = "PlaylistItemsSyncTrackerTest"

  override func setUp() {
    super.setUp()
    // Isolated UserDefaults suite so tests never touch app-standard defaults.
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    tracker = PlaylistItemsSyncTracker(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    tracker = nil
    super.tearDown()
  }

  // MARK: - Basic flag lifecycle

  func testMarkAndIsSynced() {
    XCTAssertFalse(tracker.isSynced("pl-1"))
    tracker.markSynced("pl-1")
    XCTAssertTrue(tracker.isSynced("pl-1"))
  }

  func testInvalidateClearsFlag() {
    tracker.markSynced("pl-1")
    tracker.invalidate("pl-1")
    XCTAssertFalse(tracker.isSynced("pl-1"), "Invalidated playlist must be treated as unsynced")
  }

  func testInvalidateUnsyncedIsNoOp() {
    tracker.invalidate("pl-never-synced")
    XCTAssertFalse(tracker.isSynced("pl-never-synced"))
  }

  // MARK: - Count-mismatch detection

  func testCountMismatchDetectedWhenCountsDiffer() {
    XCTAssertTrue(
      tracker.hasCountMismatch(localItemCount: 3, remoteSongCount: 5),
      "Local 3 vs remote 5 is a mismatch (playlist grew on server)"
    )
    XCTAssertTrue(
      tracker.hasCountMismatch(localItemCount: 5, remoteSongCount: 3),
      "Local 5 vs remote 3 is a mismatch (playlist shrank on server)"
    )
  }

  func testNoMismatchWhenCountsAgree() {
    XCTAssertFalse(tracker.hasCountMismatch(localItemCount: 4, remoteSongCount: 4))
  }

  func testRemoteCountZeroIsTreatedAsUnknownNotMismatch() {
    // remoteSongCount == 0 means the bulk list sync hasn't populated a count,
    // so we must NOT invalidate — we have no authoritative number to compare.
    XCTAssertFalse(
      tracker.hasCountMismatch(localItemCount: 7, remoteSongCount: 0),
      "A zero remote count is unknown, not a mismatch"
    )
  }

  // MARK: - Reconcile (the edited-after-sync fix)

  /// A playlist synced earlier but whose server count then changed gets its
  /// synced flag cleared so the next access re-fetches its items.
  func testReconcileInvalidatesSyncedPlaylistWithChangedServerCount() {
    tracker.markSynced("pl-edited")
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-edited",
      localItemCount: 2, // what we stored last sync
      remoteSongCount: 6 // server now says 6
    )
    XCTAssertTrue(didInvalidate, "Count mismatch on a synced playlist should invalidate it")
    XCTAssertFalse(tracker.isSynced("pl-edited"), "It must now be treated as unsynced")
  }

  func testReconcileLeavesMatchingPlaylistSynced() {
    tracker.markSynced("pl-stable")
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-stable",
      localItemCount: 10,
      remoteSongCount: 10
    )
    XCTAssertFalse(didInvalidate)
    XCTAssertTrue(tracker.isSynced("pl-stable"), "Matching counts must stay synced")
  }

  func testReconcileIsNoOpForUnsyncedPlaylist() {
    // Never synced → nothing to invalidate; it's already going to be re-fetched.
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-fresh",
      localItemCount: 0,
      remoteSongCount: 9
    )
    XCTAssertFalse(didInvalidate)
    XCTAssertFalse(tracker.isSynced("pl-fresh"))
  }

  func testReconcileWithZeroRemoteCountDoesNotInvalidate() {
    tracker.markSynced("pl-unknown-count")
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-unknown-count",
      localItemCount: 4,
      remoteSongCount: 0
    )
    XCTAssertFalse(didInvalidate, "Unknown (zero) remote count must not invalidate")
    XCTAssertTrue(tracker.isSynced("pl-unknown-count"))
  }
}
