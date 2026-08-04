//
//  PlaylistFolderDropTargetResolverTest.swift
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

/// Tests for what a drop onto the browse list means.
///
/// Every case here is one a mis-drop would silently corrupt the arrangement the
/// owner is rebuilding: a folder swallowed into itself, a multi-row drag landing
/// off by the number of rows lifted out above it, a reorder written while a
/// search made the visible order meaningless.
class PlaylistFolderDropTargetResolverTest: XCTestCase {
  // MARK: - Fixtures

  /// folder A, playlist One, folder B, playlist Two
  private let rowIdentities: [PlaylistFolderBrowseRowIdentity] = [
    .folder("folder-A"),
    .playlist("playlist-One"),
    .folder("folder-B"),
    .playlist("playlist-Two"),
  ]

  private func resolve(
    _ proposal: PlaylistFolderDropProposal,
    dragging draggedIdentities: [PlaylistFolderBrowseRowIdentity],
    allowsReordering: Bool = true
  )
    -> PlaylistFolderDropTarget {
    PlaylistFolderDropTargetResolver.resolve(
      proposal: proposal,
      rowIdentities: rowIdentities,
      draggedIdentities: draggedIdentities,
      allowsReordering: allowsReordering
    )
  }

  // MARK: - Dropping into a folder

  func testDropOntoAFolderRowFilesIntoThatFolder() {
    XCTAssertEqual(
      resolve(.intoRow(rowIndex: 2), dragging: [.playlist("playlist-One")]),
      .intoFolder(folderId: "folder-B")
    )
  }

  func testDropOntoAPlaylistRowIsRejected() {
    // A playlist cannot contain anything, so there is nothing to file into.
    XCTAssertEqual(
      resolve(.intoRow(rowIndex: 1), dragging: [.playlist("playlist-Two")]),
      .rejected
    )
  }

  func testFolderDroppedOntoItselfIsRejected() {
    XCTAssertEqual(
      resolve(.intoRow(rowIndex: 0), dragging: [.folder("folder-A")]),
      .rejected
    )
  }

  func testFolderDroppedOntoAFolderTravellingWithItIsRejected() {
    XCTAssertEqual(
      resolve(
        .intoRow(rowIndex: 2),
        dragging: [.folder("folder-A"), .folder("folder-B"), .playlist("playlist-One")]
      ),
      .rejected
    )
  }

  func testDropOntoAnOutOfRangeRowIsRejected() {
    XCTAssertEqual(
      resolve(.intoRow(rowIndex: 99), dragging: [.playlist("playlist-One")]),
      .rejected
    )
  }

  // MARK: - Reordering

  func testDropBetweenRowsReorders() {
    XCTAssertEqual(
      resolve(.betweenRows(rowIndex: 2), dragging: [.playlist("playlist-Two")]),
      .reorder(targetIndex: 2)
    )
  }

  func testReorderIndexIsClampedToTheList() {
    XCTAssertEqual(
      resolve(.betweenRows(rowIndex: 99), dragging: [.folder("folder-A")]),
      .reorder(targetIndex: 4)
    )
    XCTAssertEqual(
      resolve(.betweenRows(rowIndex: -3), dragging: [.folder("folder-A")]),
      .reorder(targetIndex: 0)
    )
  }

  func testReorderIsRefusedWhenTheVisibleOrderIsNotTheStoredOrder() {
    // Under a search or an attribute sort, a row index says nothing about
    // sortOrder — writing one would scramble the arrangement.
    XCTAssertEqual(
      resolve(
        .betweenRows(rowIndex: 2),
        dragging: [.playlist("playlist-One")],
        allowsReordering: false
      ),
      .rejected
    )
  }

  func testFilingIntoAFolderStillWorksWhileReorderingIsRefused() {
    // The folder is a named target, so it survives a search that kills reorder.
    XCTAssertEqual(
      resolve(
        .intoRow(rowIndex: 2),
        dragging: [.playlist("playlist-One")],
        allowsReordering: false
      ),
      .intoFolder(folderId: "folder-B")
    )
  }

  // MARK: - Background and empty drags

  func testDropOnTheBackgroundMeansThisLevel() {
    XCTAssertEqual(
      resolve(.background, dragging: [.playlist("playlist-One")]),
      .currentLevel
    )
  }

  func testDragCarryingNothingIsRejected() {
    XCTAssertEqual(resolve(.background, dragging: []), .rejected)
    XCTAssertEqual(resolve(.intoRow(rowIndex: 0), dragging: []), .rejected)
  }

  // MARK: - Insertion index adjustment

  func testInsertionIndexAccountsForRowsLiftedOutAboveTheDropPoint() {
    // Rows 0 and 1 are being dragged to index 3; once lifted out, the row that
    // was at 3 is at 1, so the landing index is 1.
    XCTAssertEqual(
      PlaylistFolderDropTargetResolver.adjustedInsertionIndex(
        targetRowIndex: 3,
        draggedRowIndices: [0, 1]
      ),
      1
    )
  }

  func testInsertionIndexIsUnchangedWhenDraggingDownwardFromBelow() {
    XCTAssertEqual(
      PlaylistFolderDropTargetResolver.adjustedInsertionIndex(
        targetRowIndex: 1,
        draggedRowIndices: [3, 4]
      ),
      1
    )
  }

  func testInsertionIndexNeverGoesNegative() {
    XCTAssertEqual(
      PlaylistFolderDropTargetResolver.adjustedInsertionIndex(
        targetRowIndex: 0,
        draggedRowIndices: [0, 1, 2]
      ),
      0
    )
  }

  // MARK: - Partitioning

  func testPartitionSplitsKindsAndKeepsOrder() {
    let partitioned = PlaylistFolderDropTargetResolver.partition([
      .playlist("p1"),
      .folder("f1"),
      .playlist("p2"),
      .folder("f2"),
    ])
    XCTAssertEqual(partitioned.folderIds, ["f1", "f2"])
    XCTAssertEqual(partitioned.playlistIds, ["p1", "p2"])
  }
}
