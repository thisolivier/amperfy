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

/// Unit tests for `PlaylistItemsSyncTracker` server-edit invalidation.
/// The tracker must re-sync a playlist the SERVER edited since we last synced
/// its items (its advertised `remoteSongCount` moved), but must NOT churn on a
/// permanent local-vs-remote gap (server counts podcast / directory /
/// unavailable entries Amperfy skips locally), which perpetually re-invalidated
/// under the old `localItemCount != remoteSongCount` rule and caused the
/// "Show in Playlists" blocking-sync storm.
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

  // MARK: - Remote-edit detection (change vs last-synced remote count)

  func testRemoteEditDetectedWhenServerCountChangedSinceLastSync() {
    tracker.markSynced("pl-1", remoteSongCount: 5)
    XCTAssertTrue(
      tracker.hasRemoteEdit(playlistId: "pl-1", remoteSongCount: 6),
      "Server count moved 5 -> 6 since last sync = a server edit"
    )
    XCTAssertTrue(
      tracker.hasRemoteEdit(playlistId: "pl-1", remoteSongCount: 4),
      "Server count moved 5 -> 4 since last sync = a server edit"
    )
  }

  func testNoRemoteEditWhenServerCountUnchangedSinceLastSync() {
    tracker.markSynced("pl-1", remoteSongCount: 5)
    XCTAssertFalse(tracker.hasRemoteEdit(playlistId: "pl-1", remoteSongCount: 5))
  }

  func testNoRemoteEditWhenNoBaselineRecorded() {
    // Marked synced without a recorded remote count → no baseline, so absent
    // any evidence of an edit we must NOT invalidate (that is exactly what the
    // old local-vs-remote rule did, causing perpetual churn).
    tracker.markSynced("pl-1")
    XCTAssertFalse(tracker.hasRemoteEdit(playlistId: "pl-1", remoteSongCount: 99))
  }

  func testRemoteCountZeroIsTreatedAsUnknownNotEdit() {
    // remoteSongCount == 0 means the bulk list sync hasn't populated a count,
    // so we must NOT invalidate — we have no authoritative number to compare.
    tracker.markSynced("pl-1", remoteSongCount: 5)
    XCTAssertFalse(
      tracker.hasRemoteEdit(playlistId: "pl-1", remoteSongCount: 0),
      "A zero remote count is unknown, not an edit"
    )
  }

  // MARK: - The podcast/unavailable-gap regression (perpetual churn fix)

  /// A playlist whose server songCount permanently exceeds its local item count
  /// (server counts a podcast/unavailable entry Amperfy skips) must stay synced
  /// pass after pass — the old `localItemCount != remoteSongCount` rule
  /// re-invalidated it forever, driving the blocking-sync storm on every open.
  func testPersistentLocalRemoteGapNeverPerpetuallyInvalidates() {
    // Synced when the server advertised 10 songs; locally only 8 resolve
    // (2 podcast/unavailable entries the parser skips). Baseline recorded = 10.
    tracker.markSynced("pl-podcast", remoteSongCount: 10)
    // Reconcile many times: the server count is stable at 10, the local gap is
    // permanent. It must never invalidate.
    for _ in 0 ..< 5 {
      let didInvalidate = tracker.reconcile(
        playlistId: "pl-podcast",
        localItemCount: 8, // permanent gap vs remote 10
        remoteSongCount: 10 // unchanged since sync
      )
      XCTAssertFalse(didInvalidate, "A permanent local/remote gap must not invalidate")
      XCTAssertTrue(tracker.isSynced("pl-podcast"))
    }
  }

  // MARK: - Reconcile (the edited-after-sync fix)

  /// A genuine server edit (the advertised count moved since last sync) still
  /// clears the synced flag so the next access re-fetches its items.
  func testReconcileInvalidatesSyncedPlaylistWithChangedServerCount() {
    tracker.markSynced("pl-edited", remoteSongCount: 3)
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-edited",
      localItemCount: 3,
      remoteSongCount: 6 // server now says 6 (was 3 at sync)
    )
    XCTAssertTrue(didInvalidate, "A server-count change on a synced playlist should invalidate it")
    XCTAssertFalse(tracker.isSynced("pl-edited"), "It must now be treated as unsynced")
  }

  func testReconcileLeavesUnchangedPlaylistSynced() {
    tracker.markSynced("pl-stable", remoteSongCount: 10)
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-stable",
      localItemCount: 10,
      remoteSongCount: 10
    )
    XCTAssertFalse(didInvalidate)
    XCTAssertTrue(tracker.isSynced("pl-stable"), "Unchanged server count must stay synced")
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
    tracker.markSynced("pl-unknown-count", remoteSongCount: 4)
    let didInvalidate = tracker.reconcile(
      playlistId: "pl-unknown-count",
      localItemCount: 4,
      remoteSongCount: 0
    )
    XCTAssertFalse(didInvalidate, "Unknown (zero) remote count must not invalidate")
    XCTAssertTrue(tracker.isSynced("pl-unknown-count"))
  }

  /// After a re-sync, the new baseline is recorded — a subsequent unchanged
  /// pass must not re-invalidate (no oscillation).
  func testReSyncRecordsNewBaselineAndStopsChurning() {
    tracker.markSynced("pl", remoteSongCount: 3)
    XCTAssertTrue(tracker.reconcile(playlistId: "pl", remoteSongCount: 6))
    // Caller re-syncs and records the new count.
    tracker.markSynced("pl", remoteSongCount: 6)
    XCTAssertFalse(
      tracker.reconcile(playlistId: "pl", remoteSongCount: 6),
      "New baseline recorded → no further invalidation"
    )
  }
}
