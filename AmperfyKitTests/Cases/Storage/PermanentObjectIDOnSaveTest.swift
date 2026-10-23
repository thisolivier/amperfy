//
//  PermanentObjectIDOnSaveTest.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — blank rows after a playlist add.
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

/// The invariant behind the blank-rows bug: **no newly inserted object may be
/// announced to the rest of the app while its object ID is still temporary.**
///
/// Every list screen in the app is an `NSFetchedResultsController` feeding a
/// `UITableViewDiffableDataSource<Int, NSManagedObjectID>`. The snapshot's item
/// identity *is* the `NSManagedObjectID`, and each cell provider resolves it
/// back with `context.existingObject(with:)`.
///
/// Core Data assigns permanent IDs during `save()` — but `save()` first calls
/// `processPendingChanges`, which posts `objectsDidChange`, which is what the
/// FRC listens to. So the FRC saw the inserts carrying **temporary** IDs,
/// published a snapshot keyed on them, and a moment later those IDs were
/// replaced by permanent ones. From then on `existingObject(with:)` threw for
/// every new row and the cell providers fell back to a bare
/// `UITableViewCell()` — a row with separators and no content. Exactly the
/// reported symptom, and it healed on navigating away because a fresh fetch
/// produced permanent IDs.
///
/// `LibraryStorage.saveContext()` therefore obtains permanent IDs *before*
/// saving. These tests pin that down at the one notification the FRC consumes.
@MainActor
final class PermanentObjectIDOnSaveTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var context: NSManagedObjectContext!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    // `LibraryStorage.context` is private; reach it the way any entity wrapper
    // would, through a managed object the library created.
    context = library.createPlaylist(account: account).managedObject.managedObjectContext
    library.saveContext()
  }

  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  /// Captures the inserted objects announced by the notification an
  /// `NSFetchedResultsController` reacts to, and whether their IDs were
  /// temporary at that instant.
  private func recordInsertedIdentityDuringChangeNotification(
    whileRunning mutation: () -> ()
  )
    -> (insertedCount: Int, temporaryCount: Int) {
    var insertedCount = 0
    var temporaryCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .NSManagedObjectContextObjectsDidChange,
      object: context,
      queue: nil
    ) { notification in
      guard let insertedObjects = notification
        .userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> else { return }
      insertedCount += insertedObjects.count
      temporaryCount += insertedObjects.filter(\.objectID.isTemporaryID).count
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    mutation()
    return (insertedCount, temporaryCount)
  }

  /// A playlist add is the reported repro. The `PlaylistItemMO`s it creates
  /// must reach the FRC with permanent IDs, or their rows render blank.
  func testPlaylistAppendAnnouncesInsertsWithPermanentIDs() throws {
    let playlist = library.createPlaylist(account: account)
    playlist.name = "My Mix"
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()

    let recorded = recordInsertedIdentityDuringChangeNotification {
      playlist.append(playables: songs)
    }

    XCTAssertGreaterThan(recorded.insertedCount, 0, "the append must announce its new items")
    XCTAssertEqual(
      recorded.temporaryCount,
      0,
      "a temporary object ID reaching the FRC is what renders the new rows blank"
    )
  }

  /// The guarantee is not specific to playlist items — every list screen keys
  /// its snapshot the same way, so it has to hold for any insert that is saved.
  func testSaveContextAnnouncesAnyInsertWithPermanentIDs() throws {
    let recorded = recordInsertedIdentityDuringChangeNotification {
      let song = library.createSong(account: account)
      song.id = "t-new"
      let playlist = library.createPlaylist(account: account)
      playlist.name = "Fresh"
      library.saveContext()
    }

    XCTAssertGreaterThan(recorded.insertedCount, 0)
    XCTAssertEqual(recorded.temporaryCount, 0)
  }

  /// And once saved the IDs are of course permanent — the snapshot identity the
  /// FRC published stays resolvable rather than being swapped out underneath it.
  func testIDsRemainStableAcrossTheSaveThatCreatedThem() throws {
    let playlist = library.createPlaylist(account: account)
    playlist.name = "My Mix"
    let song = makeSong(id: "t-1")
    library.saveContext()

    playlist.append(playable: song)
    let itemIDsAfterAppend = playlist.managedObject.items.map(\.objectID)
    XCTAssertFalse(itemIDsAfterAppend.isEmpty)
    XCTAssertTrue(
      itemIDsAfterAppend.allSatisfy { !$0.isTemporaryID },
      "items must carry permanent IDs once appended"
    )

    // A further save must not renumber them — snapshot identity has to survive.
    library.saveContext()
    XCTAssertEqual(playlist.managedObject.items.map(\.objectID), itemIDsAfterAppend)
  }
}
