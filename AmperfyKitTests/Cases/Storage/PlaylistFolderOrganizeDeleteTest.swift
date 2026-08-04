//
//  PlaylistFolderOrganizeDeleteTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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

// MARK: - CountingTreeExporter

private final class CountingTreeExporter: PlaylistFolderTreeExporter, @unchecked Sendable {
  private(set) var writeCount = 0
  func resetWriteCount() { writeCount = 0 }
  override func writeIgnoringFailure(_ export: PlaylistFolderTreeExport) { writeCount += 1 }
}

// MARK: - PlaylistFolderOrganizeDeleteTest

/// The delete gesture in the organize context.
///
/// Delete used to mean "destroy this playlist on every device you own", sitting
/// on the same key, in the same menu, as "delete this folder" — during a session
/// whose whole purpose is selecting hundreds of rows and pressing things. It now
/// means: folders are deleted, playlists come *out of the folder* and stay in
/// the library. Library deletion is not reachable from this surface at all.
@MainActor
class PlaylistFolderOrganizeDeleteTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!
  private var exporter: CountingTreeExporter!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    exporter = CountingTreeExporter(
      exportDirectoryURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaylistFolderOrganizeDeleteTest-\(UUID().uuidString)")
    )
    store = PlaylistFolderStore(
      defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!,
      treeExporter: exporter
    )
    store.configureForTesting(context: testContext, account: account.managedObject)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  @discardableResult
  private func seedPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    try? testContext.save()
    return playlist
  }

  private func libraryHoldsPlaylist(id: String) -> Bool {
    library.getPlaylists(for: account).contains { $0.id == id }
  }

  // MARK: - Playlists are unfiled, never deleted

  func testRemovingAPlaylistFromAFolderLeavesItInTheLibrary() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["pl-1"], to: folder.id)

    store.deleteFolders([], andRemovePlaylists: ["pl-1"], fromFolder: folder.id)

    XCTAssertEqual(store.folder(byId: folder.id)?.playlistIds, [])
    XCTAssertFalse(store.allFiledPlaylistIds.contains("pl-1"))
    // The point of the whole change.
    XCTAssertTrue(libraryHoldsPlaylist(id: "pl-1"))
  }

  func testRemovingFromOneFolderLeavesThePlaylistFiledInAnother() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let rockFolder = store.createFolder(name: "Rock", parent: nil)
    let jazzFolder = store.createFolder(name: "Jazz", parent: nil)
    store.addPlaylists(["pl-1"], to: rockFolder.id)
    store.addPlaylists(["pl-1"], to: jazzFolder.id)

    store.deleteFolders([], andRemovePlaylists: ["pl-1"], fromFolder: rockFolder.id)

    XCTAssertEqual(store.folder(byId: rockFolder.id)?.playlistIds, [])
    XCTAssertEqual(store.folder(byId: jazzFolder.id)?.playlistIds, ["pl-1"])
  }

  // MARK: - The root

  func testRemovingAtTheRootDropsAnExplicitRootPlacement() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["pl-1"], to: folder.id)
    // Moving it to the root gives it an explicit, ordered root placement.
    store.movePlaylists(["pl-1"], from: folder.id, to: nil)
    XCTAssertNotNil(store.playlistSortOrders(inFolder: nil)["pl-1"])

    store.deleteFolders([], andRemovePlaylists: ["pl-1"], fromFolder: nil)

    // Back to the implicit, unordered root — still there, just no longer placed.
    XCTAssertNil(store.playlistSortOrders(inFolder: nil)["pl-1"])
    XCTAssertTrue(libraryHoldsPlaylist(id: "pl-1"))
  }

  func testAnUnplacedPlaylistAtTheRootIsNotCountedAsRemovable() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    seedPlaylist(id: "pl-2", name: "Playlist 2")
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["pl-2"], to: folder.id)
    store.movePlaylists(["pl-2"], from: folder.id, to: nil)

    // pl-1 has never been placed anywhere: it is already at the top level, so
    // removing it from the top level would do nothing and must not be counted
    // into a confirmation that promises otherwise.
    XCTAssertEqual(store.placedPlaylistIds(["pl-1", "pl-2"], inFolder: nil), ["pl-2"])
  }

  func testPlacedPlaylistIdsInAFolderIgnoresPlaylistsFiledElsewhere() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    seedPlaylist(id: "pl-2", name: "Playlist 2")
    let rockFolder = store.createFolder(name: "Rock", parent: nil)
    let jazzFolder = store.createFolder(name: "Jazz", parent: nil)
    store.addPlaylists(["pl-1"], to: rockFolder.id)
    store.addPlaylists(["pl-2"], to: jazzFolder.id)

    XCTAssertEqual(
      store.placedPlaylistIds(["pl-1", "pl-2"], inFolder: rockFolder.id),
      ["pl-1"]
    )
  }

  // MARK: - Folders still delete

  func testDeletingAFolderReleasesItsContentsRatherThanDestroyingThem() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let parentFolder = store.createFolder(name: "Parent", parent: nil)
    let childFolder = store.createFolder(name: "Child", parent: parentFolder.id)
    store.addPlaylists(["pl-1"], to: childFolder.id)

    store.deleteFolders([childFolder.id], andRemovePlaylists: [], fromFolder: parentFolder.id)

    XCTAssertNil(store.folder(byId: childFolder.id))
    XCTAssertTrue(libraryHoldsPlaylist(id: "pl-1"))
  }

  // MARK: - Mixed selections

  func testAMixedGestureDeletesFoldersAndUnfilesPlaylists() {
    for index in 1 ... 3 { seedPlaylist(id: "pl-\(index)", name: "Playlist \(index)") }
    let parentFolder = store.createFolder(name: "Parent", parent: nil)
    let firstChild = store.createFolder(name: "First", parent: parentFolder.id)
    let secondChild = store.createFolder(name: "Second", parent: parentFolder.id)
    store.addPlaylists(["pl-1", "pl-2", "pl-3"], to: parentFolder.id)

    store.deleteFolders(
      [firstChild.id, secondChild.id],
      andRemovePlaylists: ["pl-1", "pl-2"],
      fromFolder: parentFolder.id
    )

    XCTAssertNil(store.folder(byId: firstChild.id))
    XCTAssertNil(store.folder(byId: secondChild.id))
    XCTAssertEqual(store.folder(byId: parentFolder.id)?.playlistIds, ["pl-3"])
    for index in 1 ... 3 {
      XCTAssertTrue(libraryHoldsPlaylist(id: "pl-\(index)"))
    }
  }

  // MARK: - One export per gesture

  func testAMixedDeleteGestureWritesExactlyOneExport() {
    for index in 1 ... 5 { seedPlaylist(id: "pl-\(index)", name: "Playlist \(index)") }
    let parentFolder = store.createFolder(name: "Parent", parent: nil)
    let firstChild = store.createFolder(name: "First", parent: parentFolder.id)
    let secondChild = store.createFolder(name: "Second", parent: parentFolder.id)
    store.addPlaylists((1 ... 5).map { "pl-\($0)" }, to: parentFolder.id)
    exporter.resetWriteCount()

    store.deleteFolders(
      [firstChild.id, secondChild.id],
      andRemovePlaylists: (1 ... 5).map { "pl-\($0)" },
      fromFolder: parentFolder.id
    )

    // Two folder deletes and five placement removals are one gesture to the
    // user, and the export's `.previous` generation has to stay one *operation*
    // behind, not one item.
    XCTAssertEqual(exporter.writeCount, 1)
  }

  func testAGestureThatChangesNothingWritesNoExport() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    exporter.resetWriteCount()

    // An unplaced playlist at the root: nothing to remove.
    store.deleteFolders([], andRemovePlaylists: ["pl-1"], fromFolder: nil)

    XCTAssertEqual(exporter.writeCount, 0)
  }
}
