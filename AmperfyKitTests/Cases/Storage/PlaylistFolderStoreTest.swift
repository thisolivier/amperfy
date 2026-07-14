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

  // MARK: - 6. Delete root folder — direct-child playlists become unfiled

  //            (they pop up to the root level, which for playlists is "unfiled")

  func testDeleteRootFolderUnfilesDirectPlaylists() {
    let folder = store.createFolder(name: "Delete Me", parent: nil)
    store.addPlaylists(["p1", "p2"], to: folder.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1", "p2"])
    store.deleteFolder(id: folder.id)
    // Folder is gone, and its direct playlists are no longer filed in any
    // folder — at root, "pop up one level" = become unfiled.
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

  // MARK: - 8. Delete parent at root — subfolders pop up to root,

  //            grandchildren stay inside their direct parent

  func testDeleteRootFolderFlattensSubfoldersAndPreservesGrandchildren() {
    // Seed: root folder "Rock" with 2 direct playlists + 1 sub-folder
    // "Metal", which itself contains 1 grandchild playlist.
    let rock = store.createFolder(name: "Rock", parent: nil)
    let metal = store.createFolder(name: "Metal", parent: rock.id)
    store.addPlaylists(["p1", "p2"], to: rock.id)
    store.addPlaylists(["p3"], to: metal.id)

    store.deleteFolder(id: rock.id)

    // "Metal" has popped up to root.
    XCTAssertEqual(store.folders.count, 1)
    XCTAssertEqual(store.folders.first?.id, metal.id)
    XCTAssertEqual(store.folders.first?.name, "Metal")
    // Grandchild playlist is still inside "Metal".
    XCTAssertEqual(store.folders.first?.playlistIds, ["p3"])
    // The 2 direct playlists of "Rock" are now unfiled (root-level for
    // playlists means "not in any folder"). Only the grandchild remains
    // filed.
    XCTAssertEqual(store.allFiledPlaylistIds, ["p3"])
  }

  // MARK: - 8b. Delete a nested folder — children pop to nested parent,

  //             not to root.

  func testDeleteNestedFolderFlattensToNestedParent() {
    // Seed: root -> "Music" -> "Rock" (contains p1) -> "Metal" (contains p2).
    let music = store.createFolder(name: "Music", parent: nil)
    let rock = store.createFolder(name: "Rock", parent: music.id)
    let metal = store.createFolder(name: "Metal", parent: rock.id)
    store.addPlaylists(["p1"], to: rock.id)
    store.addPlaylists(["p2"], to: metal.id)

    store.deleteFolder(id: rock.id)

    // Root is unchanged structurally — still only "Music".
    XCTAssertEqual(store.folders.count, 1)
    XCTAssertEqual(store.folders.first?.id, music.id)

    // "Music" now contains "Metal" (popped up from inside "Rock") and
    // playlist p1 (popped up from "Rock"'s direct playlistIds).
    let musicAfter = store.folder(byId: music.id)
    XCTAssertEqual(musicAfter?.subfolders.count, 1)
    XCTAssertEqual(musicAfter?.subfolders.first?.id, metal.id)
    XCTAssertEqual(musicAfter?.playlistIds, ["p1"])

    // "Metal" still contains p2 (grandchild preserved).
    XCTAssertEqual(store.folder(byId: metal.id)?.playlistIds, ["p2"])

    // p1 and p2 both remain filed (under "Music" and "Metal" respectively).
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1", "p2"])
  }

  // MARK: - 8c. Delete an empty folder — no crash, folder just vanishes.

  func testDeleteEmptyFolderSucceeds() {
    _ = store.createFolder(name: "Keep", parent: nil)
    let empty = store.createFolder(name: "Empty", parent: nil)
    XCTAssertEqual(store.folders.count, 2)

    store.deleteFolder(id: empty.id)

    XCTAssertEqual(store.folders.count, 1)
    XCTAssertEqual(store.folders.first?.name, "Keep")
  }

  // MARK: - 8d. Multi-filed playlist preserved — flatten-delete only unfiles

  //             relative to the deleted folder.

  func testDeleteFolderWithMultiFiledPlaylistPreservesOtherFiling() {
    let jazz = store.createFolder(name: "Jazz", parent: nil)
    let blues = store.createFolder(name: "Blues", parent: nil)
    store.addPlaylists(["p1"], to: jazz.id)
    store.addPlaylists(["p1"], to: blues.id)
    XCTAssertEqual(store.allFiledPlaylistIds, ["p1"])

    store.deleteFolder(id: jazz.id)

    // Jazz is gone; p1 is still filed in Blues.
    XCTAssertEqual(store.folders.count, 1)
    XCTAssertEqual(store.folders.first?.id, blues.id)
    XCTAssertEqual(store.folder(byId: blues.id)?.playlistIds, ["p1"])
    XCTAssertTrue(store.allFiledPlaylistIds.contains("p1"))
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

  // MARK: - 13. allPlaylistIdsRecursive on the struct traverses depth

  //             This is the primitive the root-level recursive search in
  //             PlaylistFolderContentsVC relies on to surface playlists nested
  //             anywhere in the folder tree.

  func testAllPlaylistIdsRecursiveTraversesDepth() {
    let grandchild = PlaylistFolder(name: "Metal", playlistIds: ["p3"])
    let child = PlaylistFolder(name: "Rock", playlistIds: ["p2"], subfolders: [grandchild])
    let root = PlaylistFolder(name: "Music", playlistIds: ["p1"], subfolders: [child])
    XCTAssertEqual(root.allPlaylistIdsRecursive, ["p1", "p2", "p3"])
  }

  func testAllPlaylistIdsRecursiveDeduplicatesAcrossDepth() {
    let child = PlaylistFolder(name: "Child", playlistIds: ["shared"])
    let root = PlaylistFolder(name: "Root", playlistIds: ["shared", "unique"], subfolders: [child])
    XCTAssertEqual(root.allPlaylistIdsRecursive, ["shared", "unique"])
  }

  // MARK: - 14. Recursive-search membership: a playlist filed at any depth is

  //             reported by allFiledPlaylistIds, so the root search can include
  //             it even though it is not "unfiled".

  func testDeeplyNestedPlaylistIsReportedAsFiled() {
    let root = store.createFolder(name: "Level0", parent: nil)
    let mid = store.createFolder(name: "Level1", parent: root.id)
    let leaf = store.createFolder(name: "Level2", parent: mid.id)
    store.addPlaylists(["deep"], to: leaf.id)
    XCTAssertTrue(store.allFiledPlaylistIds.contains("deep"))
  }
}
