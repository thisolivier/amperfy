//
//  PendingPlaylistSongAddStoreTest.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — playlist song adds became a durable, retried queue.
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

@MainActor
final class PendingPlaylistSongAddStoreTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PendingPlaylistSongAddStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PendingPlaylistSongAddStore(library: library)
  }

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  private func makePlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  // MARK: - Create

  /// Enqueueing writes one durable row per song, scoped to the account, and
  /// saves without being asked — an add that lives only in memory is exactly
  /// the failure this queue exists to end.
  func testEnqueueCreatesOneRowPerSongAndSaves() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2"), makeSong(id: "t-3")]
    library.saveContext()

    let createdRows = store.enqueue(songs: songs, to: playlist, account: account)

    XCTAssertEqual(createdRows.count, 3)
    XCTAssertEqual(store.pendingAddCount(for: account), 3)
    for row in createdRows {
      // A permanent object ID is proof the row reached the store: Core Data
      // only assigns one on save. If enqueue ever stopped saving, the add would
      // again be lost to an app kill — the original AMP-28 failure.
      XCTAssertFalse(
        row.objectID.isTemporaryID,
        "enqueue must save the row, not leave it only in memory"
      )
    }
    for row in createdRows {
      XCTAssertEqual(row.playlist?.id, "pl-1")
      XCTAssertEqual(row.account?.managedObject, account.managedObject)
      XCTAssertEqual(row.attemptCount, 0)
      XCTAssertNil(row.lastErrorMessage)
      XCTAssertNotNil(row.createdAt)
    }
  }

  /// An empty batch writes nothing.
  func testEnqueueEmptyBatchIsNoOp() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    library.saveContext()

    let createdRows = store.enqueue(songs: [], to: playlist, account: account)

    XCTAssertTrue(createdRows.isEmpty)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  /// A deliberate duplicate add stays two rows, so the upload sends the song
  /// twice and a rollback removes exactly two copies.
  func testEnqueueKeepsDeliberateDuplicatesAsSeparateRows() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()

    store.enqueue(songs: [song], to: playlist, account: account)
    store.enqueue(songs: [song], to: playlist, account: account)

    XCTAssertEqual(store.pendingAddCount(for: account), 2)
    XCTAssertEqual(store.pendingAdds(for: playlist).count, 2)
  }

  // MARK: - Read

  /// Rows come back oldest-first so songs reach the server in tap order — and
  /// that holds *within* one batch, where a shared timestamp would make the
  /// sort unstable.
  func testPendingAddsAreOrderedOldestFirstWithinABatch() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = (1 ... 6).map { makeSong(id: "t-\($0)") }
    library.saveContext()

    store.enqueue(songs: songs, to: playlist, account: account)

    let batches = store.pendingBatches(for: account)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.songs.map(\.id), ["t-1", "t-2", "t-3", "t-4", "t-5", "t-6"])
  }

  /// Work is grouped into one request per playlist, playlists in the order
  /// their oldest add was made.
  func testPendingBatchesGroupPerPlaylistInFirstAddOrder() throws {
    let firstPlaylist = makePlaylist(id: "pl-1", name: "First")
    let secondPlaylist = makePlaylist(id: "pl-2", name: "Second")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    let songThree = makeSong(id: "t-3")
    library.saveContext()

    let baseDate = Date(timeIntervalSince1970: 1_000)
    store.enqueue(songs: [songOne], to: firstPlaylist, account: account, now: baseDate)
    store.enqueue(
      songs: [songTwo],
      to: secondPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(1)
    )
    store.enqueue(
      songs: [songThree],
      to: firstPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(2)
    )

    let batches = store.pendingBatches(for: account)
    XCTAssertEqual(batches.count, 2, "one batch per playlist, not per enqueue call")
    XCTAssertEqual(batches[0].playlist.id, "pl-1")
    XCTAssertEqual(batches[0].songs.map(\.id), ["t-1", "t-3"])
    XCTAssertEqual(batches[1].playlist.id, "pl-2")
    XCTAssertEqual(batches[1].songs.map(\.id), ["t-2"])
  }

  /// `pendingAdds(for:)` is playlist-scoped — the reconciliation guard must not
  /// see another playlist's work.
  func testPendingAddsForPlaylistIsScopedToThatPlaylist() throws {
    let firstPlaylist = makePlaylist(id: "pl-1", name: "First")
    let secondPlaylist = makePlaylist(id: "pl-2", name: "Second")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    library.saveContext()

    store.enqueue(songs: [songOne], to: firstPlaylist, account: account)
    store.enqueue(songs: [songTwo], to: secondPlaylist, account: account)

    XCTAssertEqual(store.pendingAdds(for: firstPlaylist).map(\.song?.id), ["t-1"])
    XCTAssertEqual(store.pendingAdds(for: secondPlaylist).map(\.song?.id), ["t-2"])
  }

  /// The foreground flush needs every account that owes work, not just the
  /// active one.
  func testAccountsWithPendingAddsReportsOnlyAccountsThatOweWork() throws {
    XCTAssertTrue(store.accountsWithPendingAdds().isEmpty)
    XCTAssertFalse(store.hasAnyPendingAdds)

    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    store.enqueue(songs: [song], to: playlist, account: account)

    XCTAssertTrue(store.hasAnyPendingAdds)
    let accountsWithWork = store.accountsWithPendingAdds()
    XCTAssertEqual(accountsWithWork.count, 1)
    XCTAssertEqual(accountsWithWork.first?.managedObject, account.managedObject)
  }

  // MARK: - Update

  /// A transient failure keeps the rows, counts the attempt and remembers why.
  /// There is deliberately no attempt ceiling.
  func testRecordTransientFailureKeepsRowsAndBumpsAttemptCount() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    let rows = store.enqueue(songs: [song], to: playlist, account: account)

    store.recordTransientFailure(for: rows, message: "the network went away")
    store.recordTransientFailure(for: rows, message: "and again")

    XCTAssertEqual(store.pendingAddCount(for: account), 1, "rows survive a transient failure")
    XCTAssertEqual(rows.first?.attemptCount, 2)
    XCTAssertEqual(rows.first?.lastErrorMessage, "and again")
  }

  // MARK: - Delete

  /// Resolving rows removes them for good.
  func testDeleteRemovesRows() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    let rows = store.enqueue(songs: songs, to: playlist, account: account)

    store.delete([rows[0]])

    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertEqual(store.pendingAdds(for: playlist).map(\.song?.id), ["t-2"])

    store.delete(store.pendingAdds(for: playlist))
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  /// A row whose playlist is gone can never be uploaded, so reading sweeps it
  /// rather than handing back work that would be retried forever. (The model's
  /// cascade rule covers a playlist deleted through Core Data; the sweep is the
  /// backstop for batch deletes, which bypass delete rules.)
  func testReadingSweepsRowsWhoseTargetWentAway() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let survivingPlaylist = makePlaylist(id: "pl-2", name: "Keeper")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    library.saveContext()
    let orphanedRows = store.enqueue(songs: [songOne], to: playlist, account: account)
    store.enqueue(songs: [songTwo], to: survivingPlaylist, account: account)

    // Break the row the way a wipe would: the add no longer names a playlist.
    orphanedRows.first?.managedObject.playlist = nil
    library.saveContext()
    XCTAssertTrue(orphanedRows.first!.isOrphaned)

    let batches = store.pendingBatches(for: account)

    XCTAssertEqual(batches.count, 1, "only the still-valid playlist has work")
    XCTAssertEqual(batches.first?.playlist.id, "pl-2")
    XCTAssertEqual(store.pendingAddCount(for: account), 1, "the orphan was swept, not returned")
  }

  /// `clearStorage` uses `NSBatchDeleteRequest`, which bypasses the Playlist
  /// cascade — so the entity has to be listed for explicit deletion or a wipe
  /// would leave queued work pointing at a library that no longer exists.
  func testEntityIsRegisteredForStorageClearing() throws {
    XCTAssertTrue(
      LibraryStorage.entitiesToDelete.contains(PendingPlaylistSongAdd.typeName),
      "PendingPlaylistSongAdd must be batch-deleted on a library wipe"
    )
  }
}
