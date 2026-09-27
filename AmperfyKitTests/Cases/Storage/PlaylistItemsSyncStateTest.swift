//
//  PlaylistItemsSyncStateTest.swift
//  AmperfyKitTests
//
//  Created for AMP-19 — items-sync state moved onto the playlist row.
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
import CoreData
import XCTest

/// Unit tests for the on-row playlist items-sync state (`Playlist` sync-state
/// API, model v53 — replaces the UserDefaults-backed
/// `PlaylistItemsSyncTracker`).
///
/// The semantics under test are unchanged from the tracker era: a playlist the
/// SERVER edited since its items were last synced (its advertised
/// `remoteSongCount` moved) must be invalidated and re-fetched, but a permanent
/// local-vs-remote gap (server counts podcast / directory / unavailable entries
/// Amperfy skips locally) must NOT churn — that gap caused the
/// "Show in Playlists" blocking-sync storm under the old
/// `localItemCount != remoteSongCount` rule.
///
/// What IS new: the state lives on `PlaylistMO`, so wiping or cleaning the
/// store deletes the state with the rows — the false-confident-empty bug that
/// previously required a manual `tracker.clear()` is structurally impossible.
@MainActor
class PlaylistItemsSyncStateTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: - Helpers

  @discardableResult
  private func makePlaylist(id: String, remoteSongCount: Int = 0) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = "Playlist \(id)"
    playlist.remoteSongCount = remoteSongCount
    return playlist
  }

  @discardableResult
  private func appendSong(id: String, to playlist: Playlist) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    playlist.append(playable: song)
    return song
  }

  // MARK: - Basic flag lifecycle

  func testFreshPlaylistRowStartsUnsynced() {
    let playlist = makePlaylist(id: "pl-fresh")
    XCTAssertFalse(
      playlist.isItemsSynced,
      "A freshly created row must default to unsynced — this is what makes store wipes self-healing"
    )
  }

  func testMarkAndIsSynced() {
    let playlist = makePlaylist(id: "pl-1")
    playlist.markItemsSynced(remoteSongCount: 3)
    XCTAssertTrue(playlist.isItemsSynced)
  }

  func testInvalidateClearsFlag() {
    let playlist = makePlaylist(id: "pl-1")
    playlist.markItemsSynced(remoteSongCount: 3)
    playlist.invalidateItemsSync()
    XCTAssertFalse(playlist.isItemsSynced, "Invalidated playlist must be treated as unsynced")
  }

  func testInvalidateUnsyncedIsNoOp() {
    let playlist = makePlaylist(id: "pl-never-synced")
    playlist.invalidateItemsSync()
    XCTAssertFalse(playlist.isItemsSynced)
  }

  // MARK: - Remote-edit detection (change vs last-synced remote count)

  func testRemoteEditDetectedWhenServerCountChangedSinceLastSync() {
    let playlist = makePlaylist(id: "pl-1")
    playlist.markItemsSynced(remoteSongCount: 5)
    playlist.remoteSongCount = 6
    XCTAssertTrue(
      playlist.hasServerSideItemsEdit,
      "Server count moved 5 -> 6 since last sync = a server edit"
    )
    playlist.remoteSongCount = 4
    XCTAssertTrue(
      playlist.hasServerSideItemsEdit,
      "Server count moved 5 -> 4 since last sync = a server edit"
    )
  }

  func testNoRemoteEditWhenServerCountUnchangedSinceLastSync() {
    let playlist = makePlaylist(id: "pl-1", remoteSongCount: 5)
    playlist.markItemsSynced(remoteSongCount: 5)
    XCTAssertFalse(playlist.hasServerSideItemsEdit)
  }

  func testRemoteCountZeroIsTreatedAsUnknownNotEdit() {
    // remoteSongCount == 0 means the bulk list sync hasn't populated a count,
    // so we must NOT invalidate — we have no authoritative number to compare.
    let playlist = makePlaylist(id: "pl-1")
    playlist.markItemsSynced(remoteSongCount: 5)
    playlist.remoteSongCount = 0
    XCTAssertFalse(
      playlist.hasServerSideItemsEdit,
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
    let playlist = makePlaylist(id: "pl-podcast", remoteSongCount: 10)
    for songIndex in 0 ..< 8 {
      appendSong(id: "pl-podcast-song-\(songIndex)", to: playlist)
    }
    playlist.markItemsSynced(remoteSongCount: 10)
    // Reconcile many times: the server count is stable at 10, the local gap is
    // permanent. It must never invalidate.
    for _ in 0 ..< 5 {
      let didInvalidate = playlist.reconcileItemsSyncState()
      XCTAssertFalse(didInvalidate, "A permanent local/remote gap must not invalidate")
      XCTAssertTrue(playlist.isItemsSynced)
    }
  }

  // MARK: - Reconcile (the edited-after-sync fix)

  /// A genuine server edit (the advertised count moved since last sync) still
  /// clears the synced flag so the next access re-fetches its items.
  func testReconcileInvalidatesSyncedPlaylistWithChangedServerCount() {
    let playlist = makePlaylist(id: "pl-edited")
    playlist.markItemsSynced(remoteSongCount: 3)
    playlist.remoteSongCount = 6 // server now says 6 (was 3 at sync)
    let didInvalidate = playlist.reconcileItemsSyncState()
    XCTAssertTrue(didInvalidate, "A server-count change on a synced playlist should invalidate it")
    XCTAssertFalse(playlist.isItemsSynced, "It must now be treated as unsynced")
  }

  func testReconcileLeavesUnchangedPlaylistSynced() {
    let playlist = makePlaylist(id: "pl-stable", remoteSongCount: 10)
    playlist.markItemsSynced(remoteSongCount: 10)
    let didInvalidate = playlist.reconcileItemsSyncState()
    XCTAssertFalse(didInvalidate)
    XCTAssertTrue(playlist.isItemsSynced, "Unchanged server count must stay synced")
  }

  func testReconcileIsNoOpForUnsyncedPlaylist() {
    // Never synced → nothing to invalidate; it's already going to be re-fetched.
    let playlist = makePlaylist(id: "pl-fresh", remoteSongCount: 9)
    let didInvalidate = playlist.reconcileItemsSyncState()
    XCTAssertFalse(didInvalidate)
    XCTAssertFalse(playlist.isItemsSynced)
  }

  func testReconcileWithZeroRemoteCountDoesNotInvalidate() {
    let playlist = makePlaylist(id: "pl-unknown-count")
    playlist.markItemsSynced(remoteSongCount: 4)
    playlist.remoteSongCount = 0
    let didInvalidate = playlist.reconcileItemsSyncState()
    XCTAssertFalse(didInvalidate, "Unknown (zero) remote count must not invalidate")
    XCTAssertTrue(playlist.isItemsSynced)
  }

  /// After a re-sync, the new baseline is recorded — a subsequent unchanged
  /// pass must not re-invalidate (no oscillation).
  func testReSyncRecordsNewBaselineAndStopsChurning() {
    let playlist = makePlaylist(id: "pl")
    playlist.markItemsSynced(remoteSongCount: 3)
    playlist.remoteSongCount = 6
    XCTAssertTrue(playlist.reconcileItemsSyncState())
    // Caller re-syncs and records the new count.
    playlist.markItemsSynced(remoteSongCount: 6)
    XCTAssertFalse(
      playlist.reconcileItemsSyncState(),
      "New baseline recorded → no further invalidation"
    )
  }

  // MARK: - markItemsSyncedIfFetchLanded — the silent-offline-no-op fix

  /// `syncDown(playlist:)` opens with `guard isSyncAllowed else { return }`, so
  /// a connectivity blip returns successfully having fetched nothing. Marking
  /// the playlist synced then records a lie that reconcile can never detect
  /// (there is no remote-count CHANGE to spot), permanently hiding the
  /// playlist's membership.
  func testMarkIfFetchLandedDoesNotMarkWhenNoItemsWereFetched() {
    let playlist = makePlaylist(id: "pl-offline-blip", remoteSongCount: 12)
    let wasMarked = playlist.markItemsSyncedIfFetchLanded()
    XCTAssertFalse(wasMarked, "No local items + non-empty server = the fetch never landed")
    XCTAssertFalse(playlist.isItemsSynced)
  }

  func testMarkIfFetchLandedMarksWhenItemsArePresent() {
    let playlist = makePlaylist(id: "pl-landed", remoteSongCount: 2)
    appendSong(id: "pl-landed-song-1", to: playlist)
    appendSong(id: "pl-landed-song-2", to: playlist)
    let wasMarked = playlist.markItemsSyncedIfFetchLanded()
    XCTAssertTrue(wasMarked)
    XCTAssertTrue(playlist.isItemsSynced)
  }

  func testMarkIfFetchLandedMarksGenuinelyEmptyServerPlaylist() {
    // Server advertises 0 songs: nothing to fetch, so nothing to prove.
    let playlist = makePlaylist(id: "pl-empty", remoteSongCount: 0)
    let wasMarked = playlist.markItemsSyncedIfFetchLanded()
    XCTAssertTrue(wasMarked)
    XCTAssertTrue(playlist.isItemsSynced)
  }

  // MARK: - State dies with the row (the AMP-19 fix itself)

  /// The resync/cleanup path (`cleanStorageOfObsoleteAccountEntries`) deletes
  /// PlaylistMO rows and the initial sync re-creates them from metadata. The
  /// re-created rows must start unsynced — no `clear()` step exists any more,
  /// the row default IS the honesty guarantee. This is the regression test for
  /// the 2026-08-02 false-confident-empty incident, restated for the on-row
  /// model.
  func testRecreatedPlaylistRowAfterWipeStartsUnsynced() {
    let playlist = makePlaylist(id: "pl-era04", remoteSongCount: 17)
    playlist.markItemsSynced(remoteSongCount: 17)
    XCTAssertTrue(playlist.isItemsSynced)

    // The wipe: the row is deleted outright (as cleanStorage... does).
    library.deletePlaylist(playlist)
    library.saveContext()

    // The initial sync re-creates the playlist from server metadata.
    let recreatedPlaylist = makePlaylist(id: "pl-era04", remoteSongCount: 17)
    library.saveContext()

    XCTAssertFalse(
      recreatedPlaylist.isItemsSynced,
      "A re-created row starts unsynced, so the completeness guard reports 'still syncing' instead of a confident, wrong empty"
    )
  }
}
