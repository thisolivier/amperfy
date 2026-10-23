//
//  PendingPlaylistSongAddStoreTest.swift
//  AmperfyKitTests
//
//  Created by Olivier Butler on 23.10.26.
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
  private var cdHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PendingPlaylistSongAddStore!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PendingPlaylistSongAddStore(library: library)
  }

  @discardableResult
  private func createSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  private func createPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  // MARK: - Create

  /// Queueing writes one durable entry per song, scoped to the account, and
  /// saves without being asked — an add that lives only in memory is exactly
  /// the failure this queue exists to end.
  func testEnqueueCreatesOneEntryPerSongAndSaves() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2"), createSong(id: "t-3")]
    library.saveContext()

    let pendingAdds = store.enqueue(songs: songs, to: playlist, account: account)

    XCTAssertEqual(pendingAdds.count, 3)
    XCTAssertEqual(store.pendingAddCount(for: account), 3)
    for pendingAdd in pendingAdds {
      // A permanent object ID is proof the entry reached the store: Core Data
      // only assigns one on save. If enqueue ever stopped saving, the add would
      // again be lost when the app is killed.
      XCTAssertFalse(
        pendingAdd.objectID.isTemporaryID,
        "enqueue must save, not leave the add only in memory"
      )
      XCTAssertEqual(pendingAdd.playlist?.id, "pl-1")
      XCTAssertEqual(pendingAdd.account?.managedObject, account.managedObject)
      XCTAssertEqual(pendingAdd.attemptCount, 0)
      XCTAssertNil(pendingAdd.lastErrorMessage)
      XCTAssertNotNil(pendingAdd.createdAt)
    }
  }

  func testEnqueueEmptyBatchIsNoOp() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    library.saveContext()

    let pendingAdds = store.enqueue(songs: [], to: playlist, account: account)

    XCTAssertTrue(pendingAdds.isEmpty)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  /// A deliberate duplicate add stays two entries, so the upload sends the song
  /// twice and a rollback removes exactly two copies.
  func testEnqueueKeepsDeliberateDuplicatesAsSeparateEntries() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()

    store.enqueue(songs: [song], to: playlist, account: account)
    store.enqueue(songs: [song], to: playlist, account: account)

    XCTAssertEqual(store.pendingAddCount(for: account), 2)
    XCTAssertEqual(store.pendingAdds(for: playlist).count, 2)
  }

  // MARK: - Read

  /// Entries come back oldest first so songs reach the server in selection
  /// order — and that holds within one batch, where a shared timestamp would
  /// make the sort unstable.
  func testPendingAddsAreOrderedOldestFirstWithinABatch() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = (1 ... 6).map { createSong(id: "t-\($0)") }
    library.saveContext()

    store.enqueue(songs: songs, to: playlist, account: account)

    let batches = store.pendingBatches(for: account)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.songs.map(\.id), ["t-1", "t-2", "t-3", "t-4", "t-5", "t-6"])
  }

  /// Work is grouped into one request per playlist, playlists in the order
  /// their oldest add was made.
  func testPendingBatchesGroupPerPlaylistInFirstAddOrder() throws {
    let firstPlaylist = createPlaylist(id: "pl-1", name: "First")
    let secondPlaylist = createPlaylist(id: "pl-2", name: "Second")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
    let songThree = createSong(id: "t-3")
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

  /// `pendingAdds(for:)` is playlist scoped — the reconciliation guard must not
  /// see another playlist's work.
  func testPendingAddsForPlaylistIsScopedToThatPlaylist() throws {
    let firstPlaylist = createPlaylist(id: "pl-1", name: "First")
    let secondPlaylist = createPlaylist(id: "pl-2", name: "Second")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
    library.saveContext()

    store.enqueue(songs: [songOne], to: firstPlaylist, account: account)
    store.enqueue(songs: [songTwo], to: secondPlaylist, account: account)

    XCTAssertEqual(store.pendingAdds(for: firstPlaylist).map(\.song?.id), ["t-1"])
    XCTAssertEqual(store.pendingAdds(for: secondPlaylist).map(\.song?.id), ["t-2"])
  }

  /// Another account's queued work must not be picked up by this account's
  /// upload pass.
  func testPendingAddsAreScopedToTheirAccount() throws {
    let otherAccount = library.getAccount(info: TestAccountInfo.create2())
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()

    store.enqueue(songs: [song], to: playlist, account: account)

    XCTAssertTrue(store.hasAnyPendingAdds)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertEqual(store.pendingAddCount(for: otherAccount), 0)
    XCTAssertTrue(store.pendingBatches(for: otherAccount).isEmpty)
  }

  // MARK: - Update

  /// A transient failure keeps the entries, counts the attempt and remembers
  /// why. There is deliberately no attempt ceiling.
  func testRecordTransientFailureKeepsEntriesAndBumpsAttemptCount() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    let pendingAdds = store.enqueue(songs: [song], to: playlist, account: account)

    store.recordTransientFailure(for: pendingAdds, message: "the network went away")
    store.recordTransientFailure(for: pendingAdds, message: "and again")

    XCTAssertEqual(
      store.pendingAddCount(for: account),
      1,
      "the add survives a transient failure"
    )
    XCTAssertEqual(pendingAdds.first?.attemptCount, 2)
    XCTAssertEqual(pendingAdds.first?.lastErrorMessage, "and again")
  }

  // MARK: - Delete

  func testDeleteRemovesEntries() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
    library.saveContext()
    let pendingAdds = store.enqueue(songs: songs, to: playlist, account: account)

    store.delete([pendingAdds[0]])

    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertEqual(store.pendingAdds(for: playlist).map(\.song?.id), ["t-2"])

    store.delete(store.pendingAdds(for: playlist))
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  /// An add whose playlist is gone can never be uploaded, so reading sweeps it
  /// rather than handing back work that would be retried forever. The model's
  /// cascade rule covers a playlist deleted through Core Data; the sweep is the
  /// backstop for batch deletes, which bypass delete rules.
  func testReadingSweepsEntriesWhoseTargetWentAway() throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let survivingPlaylist = createPlaylist(id: "pl-2", name: "Keeper")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
    library.saveContext()
    let orphanedAdds = store.enqueue(songs: [songOne], to: playlist, account: account)
    store.enqueue(songs: [songTwo], to: survivingPlaylist, account: account)

    // Break the entry the way a wipe would: the add no longer names a playlist.
    orphanedAdds.first?.managedObject.playlist = nil
    library.saveContext()
    XCTAssertTrue(orphanedAdds.first!.isOrphaned)

    let batches = store.pendingBatches(for: account)

    XCTAssertEqual(batches.count, 1, "only the still-valid playlist has work")
    XCTAssertEqual(batches.first?.playlist.id, "pl-2")
    XCTAssertEqual(store.pendingAddCount(for: account), 1, "the orphan was swept, not returned")
  }

  /// `clearStorage` uses `NSBatchDeleteRequest`, which bypasses the Playlist
  /// cascade — so the entity has to be listed for explicit deletion, or a wipe
  /// would leave queued work pointing at a library that no longer exists.
  func testEntityIsRegisteredForStorageClearing() throws {
    XCTAssertTrue(
      LibraryStorage.entitiesToDelete.contains(PendingPlaylistSongAdd.typeName),
      "PendingPlaylistSongAdd must be batch-deleted on a library wipe"
    )
  }
}
