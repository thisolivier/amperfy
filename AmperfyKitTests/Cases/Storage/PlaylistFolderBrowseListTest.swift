//
//  PlaylistFolderBrowseListTest.swift
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
import XCTest

/// Tests for the browse list row order.
///
/// The property under test: folders render as a block ahead of the playlists in
/// every sort option, while both kinds keep sharing one sortOrder space per
/// parent. Within each block the sibling comparator orders as usual.
class PlaylistFolderBrowseListTest: XCTestCase {
  // MARK: - Helpers

  private func folderSibling(_ name: String, sortOrder: Int?) -> PlaylistFolderSibling {
    PlaylistFolderSibling(kind: .folder, id: "f-\(name)", name: name, sortOrder: sortOrder)
  }

  private func playlistSibling(_ name: String, sortOrder: Int?) -> PlaylistFolderSibling {
    PlaylistFolderSibling(kind: .playlist, id: "p-\(name)", name: name, sortOrder: sortOrder)
  }

  private func rowIds(_ identities: [PlaylistFolderBrowseRowIdentity]) -> [String] {
    identities.map(\.id)
  }

  // MARK: - Folder-block-first ordering

  func testFoldersRenderAheadOfPlaylistsWhateverTheSortOrders() {
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [folderSibling("Rock", sortOrder: 10), folderSibling("Jazz", sortOrder: 30)],
      playlistSiblings: [playlistSibling("Mix", sortOrder: 20)]
    )
    // The playlist's sortOrder sits numerically between the folders', but the
    // folder block still renders first.
    XCTAssertEqual(rowIds(identities), ["f-Rock", "f-Jazz", "p-Mix"])
  }

  func testUnorderedSiblingsFollowOrderedOnesWithinTheirBlock() {
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [folderSibling("Zeta", sortOrder: nil)],
      playlistSiblings: [
        playlistSibling("Alpha", sortOrder: nil),
        playlistSibling("Ordered", sortOrder: 10),
      ]
    )
    // Even unordered, the folder leads; within the playlist block the ordered
    // playlist precedes the unordered one.
    XCTAssertEqual(rowIds(identities), ["f-Zeta", "p-Ordered", "p-Alpha"])
  }

  func testAllUnorderedSiblingsSegregateByKindThenName() {
    // The fresh-install state: nothing has a sortOrder yet. Folders must still
    // form their own block at the top instead of mixing in alphabetically —
    // this exact state shipped as the mixed-in-on-first-listing bug.
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [
        folderSibling("Zebra Folder", sortOrder: nil),
        folderSibling("Alpha Folder", sortOrder: nil),
      ],
      playlistSiblings: [
        playlistSibling("Beta Playlist", sortOrder: nil),
        playlistSibling("Aardvark Playlist", sortOrder: nil),
      ]
    )
    XCTAssertEqual(
      rowIds(identities),
      ["f-Alpha Folder", "f-Zebra Folder", "p-Aardvark Playlist", "p-Beta Playlist"]
    )
  }

  func testTiesOnSortOrderKeepFoldersFirst() {
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [folderSibling("Beta", sortOrder: 10)],
      playlistSiblings: [playlistSibling("Alpha", sortOrder: 10)]
    )
    XCTAssertEqual(rowIds(identities), ["f-Beta", "p-Alpha"])
  }

  func testEmptyInputsProduceEmptyList() {
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [],
      playlistSiblings: []
    )
    XCTAssertTrue(identities.isEmpty)
  }

  // MARK: - Attribute sort

  func testAttributeSortKeepsFoldersFirstAndPreservesGivenOrder() {
    // Under an attribute sort the caller has already ordered each group; the
    // builder must not re-sort them, only concatenate.
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [folderSibling("Zeta", sortOrder: 99), folderSibling("Alpha", sortOrder: 1)],
      playlistSiblings: [
        playlistSibling("Longest", sortOrder: nil),
        playlistSibling("Shortest", sortOrder: nil),
      ],
      keepsFoldersFirst: true
    )
    XCTAssertEqual(rowIds(identities), ["f-Zeta", "f-Alpha", "p-Longest", "p-Shortest"])
  }

  // MARK: - Row lookup

  func testRowIndexFindsAndMissesCorrectly() {
    let identities = PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: [folderSibling("Rock", sortOrder: 10)],
      playlistSiblings: [playlistSibling("Mix", sortOrder: 20)]
    )
    XCTAssertEqual(
      PlaylistFolderBrowseListBuilder.rowIndex(of: .playlist("p-Mix"), in: identities),
      1
    )
    XCTAssertNil(
      PlaylistFolderBrowseListBuilder.rowIndex(of: .playlist("p-Absent"), in: identities)
    )
  }

  func testFolderAndPlaylistWithTheSameIdAreDifferentRows() {
    // Nothing stops a folder id and a playlist id being equal strings, so the
    // kind has to be part of identity or a drag would target the wrong row.
    XCTAssertNotEqual(
      PlaylistFolderBrowseRowIdentity.folder("shared-id"),
      PlaylistFolderBrowseRowIdentity.playlist("shared-id")
    )
  }

  // MARK: - Identity encoding

  func testIdentityEncodingRoundTrips() {
    for identity in [
      PlaylistFolderBrowseRowIdentity.folder("F-123"),
      PlaylistFolderBrowseRowIdentity.playlist("p-456"),
    ] {
      XCTAssertEqual(
        PlaylistFolderBrowseRowIdentity(encodedString: identity.encodedString),
        identity
      )
    }
  }

  func testIdentityDecodingKeepsColonsInsideTheId() {
    let decoded = PlaylistFolderBrowseRowIdentity(encodedString: "playlist:weird:id:here")
    XCTAssertEqual(decoded, .playlist("weird:id:here"))
  }

  func testIdentityDecodingRejectsGarbage() {
    XCTAssertNil(PlaylistFolderBrowseRowIdentity(encodedString: "no-separator"))
    XCTAssertNil(PlaylistFolderBrowseRowIdentity(encodedString: "unknownKind:abc"))
    XCTAssertNil(PlaylistFolderBrowseRowIdentity(encodedString: "folder:"))
  }
}
