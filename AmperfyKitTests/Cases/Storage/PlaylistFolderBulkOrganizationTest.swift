//
//  PlaylistFolderBulkOrganizationTest.swift
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

/// Counts export writes instead of performing them.
///
/// The batching guarantee is only observable by counting: the folder state after
/// one export and after forty is identical, and the difference — forty rolls of
/// the `.previous` generation, destroying the last pre-operation snapshot — is
/// exactly what the safety net exists to prevent.
private final class CountingTreeExporter: PlaylistFolderTreeExporter, @unchecked Sendable {
  private(set) var writeCount = 0

  func resetWriteCount() { writeCount = 0 }

  override func writeIgnoringFailure(_ export: PlaylistFolderTreeExport) {
    writeCount += 1
  }
}

// MARK: - PlaylistFolderBulkOrganizationTest

/// Tests for the bulk organization write paths added for the folder rebuild:
/// plural moves, mixed folder/playlist moves, new-folder-from-selection, and the
/// coalescing that keeps them to one export and one notification apiece.
@MainActor
class PlaylistFolderBulkOrganizationTest: XCTestCase {
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
        .appendingPathComponent("PlaylistFolderBulkOrganizationTest-\(UUID().uuidString)")
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

  private func playlistIds(inFolder folderId: String) -> [String] {
    store.folder(byId: folderId)?.playlistIds ?? []
  }

  // MARK: - Moving playlists in bulk

  func testMovePlaylistsMovesEveryOneOutOfTheSourceFolder() {
    for index in 1 ... 3 { seedPlaylist(id: "p\(index)", name: "Playlist \(index)") }
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists(["p1", "p2", "p3"], to: source.id)

    store.movePlaylists(["p1", "p2", "p3"], from: source.id, to: destination.id)

    XCTAssertEqual(playlistIds(inFolder: source.id), [])
    XCTAssertEqual(playlistIds(inFolder: destination.id), ["p1", "p2", "p3"])
  }

  func testMovePlaylistsKeepsPlacementsInFoldersItWasNotMovedOutOf() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let source = store.createFolder(name: "Source", parent: nil)
    let other = store.createFolder(name: "Other", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists(["p1"], to: source.id)
    store.addPlaylists(["p1"], to: other.id)

    store.movePlaylists(["p1"], from: source.id, to: destination.id)

    XCTAssertEqual(playlistIds(inFolder: source.id), [])
    XCTAssertEqual(playlistIds(inFolder: destination.id), ["p1"])
    // Multiplicity is the point of placements: a move out of one folder must not
    // quietly evict the playlist from its other homes.
    XCTAssertEqual(playlistIds(inFolder: other.id), ["p1"])
  }

  func testMovePlaylistsFromRootFilesPreviouslyUnfiledPlaylists() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let destination = store.createFolder(name: "Destination", parent: nil)

    store.movePlaylists(["p1"], from: nil, to: destination.id)

    XCTAssertEqual(playlistIds(inFolder: destination.id), ["p1"])
    XCTAssertTrue(store.allFiledPlaylistIds.contains("p1"))
  }

  func testMovePlaylistsToRootLeavesTheFolderAndGainsAnExplicitRootPlacement() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let source = store.createFolder(name: "Source", parent: nil)
    store.addPlaylists(["p1"], to: source.id)

    store.movePlaylists(["p1"], from: source.id, to: nil)

    XCTAssertEqual(playlistIds(inFolder: source.id), [])
    // An explicit root placement is ordered at root, so it is *not* "filed".
    XCTAssertFalse(store.allFiledPlaylistIds.contains("p1"))
    XCTAssertNotNil(store.playlistSortOrders(inFolder: nil)["p1"])
  }

  func testMovePlaylistsToTheFolderTheyAreAlreadyInDoesNothing() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let folder = store.createFolder(name: "Folder", parent: nil)
    store.addPlaylists(["p1"], to: folder.id)
    exporter.resetWriteCount()

    store.movePlaylists(["p1"], from: folder.id, to: folder.id)

    XCTAssertEqual(playlistIds(inFolder: folder.id), ["p1"])
    XCTAssertEqual(exporter.writeCount, 0)
  }

  func testMovePlaylistsKeepsTheSelectionOrder() {
    for index in 1 ... 3 { seedPlaylist(id: "p\(index)", name: "Playlist \(index)") }
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists(["p1", "p2", "p3"], to: source.id)

    store.movePlaylists(["p3", "p1", "p2"], from: source.id, to: destination.id)

    XCTAssertEqual(playlistIds(inFolder: destination.id), ["p3", "p1", "p2"])
  }

  // MARK: - Moving folders in bulk

  func testMoveFoldersReparentsEveryOne() {
    let destination = store.createFolder(name: "Destination", parent: nil)
    let first = store.createFolder(name: "First", parent: nil)
    let second = store.createFolder(name: "Second", parent: nil)

    store.moveFolders([first.id, second.id], toParent: destination.id)

    let subfolderNames = store.folder(byId: destination.id)?.subfolders.map(\.name) ?? []
    XCTAssertEqual(Set(subfolderNames), ["First", "Second"])
    XCTAssertEqual(store.folders.map(\.name), ["Destination"])
  }

  func testMoveFoldersRefusesTheCycleButAppliesTheLegalPartOfTheSelection() {
    let outer = store.createFolder(name: "Outer", parent: nil)
    let inner = store.createFolder(name: "Inner", parent: outer.id)
    let sibling = store.createFolder(name: "Sibling", parent: nil)

    // Moving Outer into its own child is a cycle; Sibling is fine.
    store.moveFolders([outer.id, sibling.id], toParent: inner.id)

    XCTAssertEqual(store.folders.map(\.name), ["Outer"])
    let innerSubfolderNames = store.folder(byId: inner.id)?.subfolders.map(\.name) ?? []
    XCTAssertEqual(innerSubfolderNames, ["Sibling"])
  }

  // MARK: - Mixed selections

  func testMoveSiblingsMovesFoldersAndPlaylistsTogether() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    let child = store.createFolder(name: "Child", parent: source.id)
    store.addPlaylists(["p1"], to: source.id)

    store.moveSiblings(
      folderIds: [child.id],
      playlistIds: ["p1"],
      from: source.id,
      to: destination.id
    )

    XCTAssertEqual(playlistIds(inFolder: destination.id), ["p1"])
    XCTAssertEqual(store.folder(byId: destination.id)?.subfolders.map(\.name), ["Child"])
  }

  // MARK: - New folder from selection

  func testCreateFolderFromSelectionCreatesItHereAndMovesTheSelectionIn() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    seedPlaylist(id: "p2", name: "Playlist 2")
    let existing = store.createFolder(name: "Existing", parent: nil)

    let newFolder = store.createFolder(
      named: "Grouped",
      in: nil,
      movingFolders: [existing.id],
      playlists: ["p1", "p2"]
    )

    let newFolderId = try? XCTUnwrap(newFolder?.id)
    guard let newFolderId else { return XCTFail("folder was not created") }
    XCTAssertEqual(playlistIds(inFolder: newFolderId), ["p1", "p2"])
    XCTAssertEqual(store.folder(byId: newFolderId)?.subfolders.map(\.name), ["Existing"])
    XCTAssertEqual(store.folders.map(\.name), ["Grouped"])
  }

  // MARK: - One export per user action

  func testBulkMoveWritesExactlyOneExportRatherThanOnePerPlaylist() {
    for index in 1 ... 8 { seedPlaylist(id: "p\(index)", name: "Playlist \(index)") }
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists((1 ... 8).map { "p\($0)" }, to: source.id)
    exporter.resetWriteCount()

    store.movePlaylists((1 ... 8).map { "p\($0)" }, from: source.id, to: destination.id)

    XCTAssertEqual(exporter.writeCount, 1)
    XCTAssertEqual(playlistIds(inFolder: destination.id).count, 8)
  }

  func testUnbatchedIndividualMovesWouldWriteOneExportEach() {
    // The control for the test above: the per-item primitive still exports per
    // item, which is why the bulk paths have to batch rather than loop.
    for index in 1 ... 4 { seedPlaylist(id: "p\(index)", name: "Playlist \(index)") }
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists((1 ... 4).map { "p\($0)" }, to: source.id)
    exporter.resetWriteCount()

    for index in 1 ... 4 {
      store.movePlaylist("p\(index)", from: source.id, to: destination.id)
    }

    XCTAssertEqual(exporter.writeCount, 4)
  }

  func testMixedBulkMoveOfFoldersAndPlaylistsStillWritesOneExport() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    seedPlaylist(id: "p2", name: "Playlist 2")
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    let firstChild = store.createFolder(name: "First", parent: source.id)
    let secondChild = store.createFolder(name: "Second", parent: source.id)
    store.addPlaylists(["p1", "p2"], to: source.id)
    exporter.resetWriteCount()

    store.moveSiblings(
      folderIds: [firstChild.id, secondChild.id],
      playlistIds: ["p1", "p2"],
      from: source.id,
      to: destination.id
    )

    XCTAssertEqual(exporter.writeCount, 1)
  }

  func testNewFolderFromSelectionWritesOneExportForTheWholeAction() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    seedPlaylist(id: "p2", name: "Playlist 2")
    let existing = store.createFolder(name: "Existing", parent: nil)
    exporter.resetWriteCount()

    store.createFolder(
      named: "Grouped",
      in: nil,
      movingFolders: [existing.id],
      playlists: ["p1", "p2"]
    )

    // The folder creation and all three moves are one action to the user.
    XCTAssertEqual(exporter.writeCount, 1)
  }

  func testBatchedUpdatesPostExactlyOneChangeNotification() {
    for index in 1 ... 5 { seedPlaylist(id: "p\(index)", name: "Playlist \(index)") }
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists((1 ... 5).map { "p\($0)" }, to: source.id)

    var notificationCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: PlaylistFolderStore.didChangeNotification,
      object: store,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.movePlaylists((1 ... 5).map { "p\($0)" }, from: source.id, to: destination.id)

    XCTAssertEqual(notificationCount, 1)
  }

  func testNestedBatchesFlushOnlyOnceAtTheOutermostLevel() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let source = store.createFolder(name: "Source", parent: nil)
    let destination = store.createFolder(name: "Destination", parent: nil)
    store.addPlaylists(["p1"], to: source.id)
    exporter.resetWriteCount()

    store.performBatchedUpdates {
      // `moveSiblings` opens a batch of its own, which itself opens two more.
      store.moveSiblings(
        folderIds: [],
        playlistIds: ["p1"],
        from: source.id,
        to: destination.id
      )
      store.renameFolder(id: destination.id, to: "Renamed")
    }

    XCTAssertEqual(exporter.writeCount, 1)
    XCTAssertEqual(store.folder(byId: destination.id)?.name, "Renamed")
  }

  func testABatchThatChangesNothingWritesNoExport() {
    exporter.resetWriteCount()
    store.performBatchedUpdates {}
    XCTAssertEqual(exporter.writeCount, 0)
  }

  func testExportsResumeNormallyAfterABatchCompletes() {
    seedPlaylist(id: "p1", name: "Playlist 1")
    let folder = store.createFolder(name: "Folder", parent: nil)
    store.performBatchedUpdates {
      store.addPlaylists(["p1"], to: folder.id)
    }
    exporter.resetWriteCount()

    store.renameFolder(id: folder.id, to: "Renamed")

    XCTAssertEqual(exporter.writeCount, 1)
  }
}
