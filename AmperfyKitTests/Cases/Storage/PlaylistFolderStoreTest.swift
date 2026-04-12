//
//  PlaylistFolderStoreTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (Feature G — Playlist folders).
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

/// Unit tests for `PlaylistFolderStore` (Feature G — playlist folders).
@MainActor
class PlaylistFolderStoreTest: XCTestCase {
  private var suiteName: String!
  private var testDefaults: UserDefaults!
  private var store: PlaylistFolderStore!

  override func setUp() {
    super.setUp()
    suiteName = "PlaylistFolderStoreTest.\(UUID().uuidString)"
    testDefaults = UserDefaults(suiteName: suiteName)!
    store = PlaylistFolderStore(defaults: testDefaults)
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  // MARK: - 1. Empty state

  func testEmptyStateHasNoFoldersOrFiledIds() {
    XCTAssertTrue(store.folders.isEmpty)
    XCTAssertTrue(store.allFiledPlaylistIds.isEmpty)
  }

  // MARK: - 2. Create folder + add playlist

  func testCreateFolderAndAddPlaylist() {
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["p1"], to: folder.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1"])
    XCTAssertEqual(store.folder(byId: folder.id)?.playlistIds, ["p1"])
  }

  // MARK: - 3. Same playlist in two folders

  func testPlaylistInTwoFoldersAppearsOnceInFiledIds() {
    let folderA = store.createFolder(name: "A", parent: nil)
    let folderB = store.createFolder(name: "B", parent: nil)
    store.addPlaylists(["p1"], to: folderA.id)
    store.addPlaylists(["p1"], to: folderB.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1"])
    XCTAssertEqual(store.folder(byId: folderA.id)?.playlistIds, ["p1"])
    XCTAssertEqual(store.folder(byId: folderB.id)?.playlistIds, ["p1"])
  }

  // MARK: - 4. Remove from one folder — still filed in other

  func testRemoveFromOneFolderStillFiledInOther() {
    let folderA = store.createFolder(name: "A", parent: nil)
    let folderB = store.createFolder(name: "B", parent: nil)
    store.addPlaylists(["p1"], to: folderA.id)
    store.addPlaylists(["p1"], to: folderB.id)
    store.removePlaylists(["p1"], from: folderA.id)
    XCTAssertTrue(store.allFiledPlaylistIds.contains("p1"))
    XCTAssertEqual(store.folder(byId: folderA.id)?.playlistIds, [])
    XCTAssertEqual(store.folder(byId: folderB.id)?.playlistIds, ["p1"])
  }

  // MARK: - 5. Remove from both — unfiled

  func testRemoveFromBothFoldersBecomesUnfiled() {
    let folderA = store.createFolder(name: "A", parent: nil)
    let folderB = store.createFolder(name: "B", parent: nil)
    store.addPlaylists(["p1"], to: folderA.id)
    store.addPlaylists(["p1"], to: folderB.id)
    store.removePlaylists(["p1"], from: folderA.id)
    store.removePlaylists(["p1"], from: folderB.id)
    XCTAssertTrue(store.allFiledPlaylistIds.isEmpty)
  }

  // MARK: - 6. Delete folder — playlists become unfiled

  func testDeleteFolderUnfilesPlaylists() {
    let folder = store.createFolder(name: "Delete Me", parent: nil)
    store.addPlaylists(["p1", "p2"], to: folder.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1", "p2"])
    store.deleteFolder(id: folder.id)
    XCTAssertTrue(store.folders.isEmpty)
    XCTAssertTrue(store.allFiledPlaylistIds.isEmpty)
  }

  // MARK: - 7. Nested subfolder — allFiledPlaylistIds traverses depth

  func testNestedSubfolderPlaylistIdsTraverseDepth() {
    let parent = store.createFolder(name: "Parent", parent: nil)
    let child = store.createFolder(name: "Child", parent: parent.id)
    store.addPlaylists(["p1"], to: parent.id)
    store.addPlaylists(["p2"], to: child.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1", "p2"])
  }

  // MARK: - 8. Delete parent — subfolders and memberships removed

  func testDeleteParentRemovesSubfoldersAndMemberships() {
    let parent = store.createFolder(name: "Parent", parent: nil)
    let child = store.createFolder(name: "Child", parent: parent.id)
    store.addPlaylists(["p1"], to: parent.id)
    store.addPlaylists(["p2"], to: child.id)
    store.deleteFolder(id: parent.id)
    XCTAssertTrue(store.folders.isEmpty)
    XCTAssertTrue(store.allFiledPlaylistIds.isEmpty)
  }

  // MARK: - 9. Rename persists across instances

  func testRenamePersistsAcrossInstances() {
    let folder = store.createFolder(name: "Old Name", parent: nil)
    store.renameFolder(id: folder.id, to: "New Name")
    let secondStore = PlaylistFolderStore(defaults: testDefaults)
    XCTAssertEqual(secondStore.folders.first?.name, "New Name")
  }

  // MARK: - 10. Notification fires on mutation

  func testNotificationFiresOnMutation() {
    let expectation = expectation(description: "didChangeNotification fires")
    let observer = NotificationCenter.default.addObserver(
      forName: PlaylistFolderStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      expectation.fulfill()
    }
    store.createFolder(name: "Trigger", parent: nil)
    waitForExpectations(timeout: 2)
    NotificationCenter.default.removeObserver(observer)
  }

  // MARK: - 11. JSON round-trip

  func testJsonRoundTrip() {
    let parent = store.createFolder(name: "Parent", parent: nil)
    store.createFolder(name: "Child", parent: parent.id)
    store.addPlaylists(["p1", "p2"], to: parent.id)

    let secondStore = PlaylistFolderStore(defaults: testDefaults)
    XCTAssertEqual(secondStore.folders.count, 1)
    XCTAssertEqual(secondStore.folders.first?.name, "Parent")
    XCTAssertEqual(secondStore.folders.first?.playlistIds, ["p1", "p2"])
    XCTAssertEqual(secondStore.folders.first?.subfolders.count, 1)
    XCTAssertEqual(secondStore.folders.first?.subfolders.first?.name, "Child")
  }

  // MARK: - 12. Move playlist between folders

  func testMovePlaylistBetweenFolders() {
    let folderA = store.createFolder(name: "Source", parent: nil)
    let folderB = store.createFolder(name: "Dest", parent: nil)
    store.addPlaylists(["p1"], to: folderA.id)
    store.movePlaylist("p1", from: folderA.id, to: folderB.id)
    XCTAssertEqual(store.folder(byId: folderA.id)?.playlistIds, [])
    XCTAssertEqual(store.folder(byId: folderB.id)?.playlistIds, ["p1"])
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1"])
  }
}
