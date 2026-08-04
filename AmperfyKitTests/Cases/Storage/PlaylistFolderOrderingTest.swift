//
//  PlaylistFolderOrderingTest.swift
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

/// Tests for the sibling comparator and the gap-numbering scheme.
///
/// Both are pure, and both encode contract decisions the server cannot enforce:
/// sortOrder values are client-assigned, unnormalized, and duplicates are legal,
/// so the client is solely responsible for producing a stable order out of them.
class PlaylistFolderOrderingTest: XCTestCase {
  // MARK: - Helpers

  private func folderSibling(_ name: String, sortOrder: Int?) -> PlaylistFolderSibling {
    PlaylistFolderSibling(
      kind: .folder, id: "folder-\(name)", name: name, sortOrder: sortOrder
    )
  }

  private func playlistSibling(_ name: String, sortOrder: Int?) -> PlaylistFolderSibling {
    PlaylistFolderSibling(
      kind: .playlist, id: "playlist-\(name)", name: name, sortOrder: sortOrder
    )
  }

  private func sortedNames(_ siblings: [PlaylistFolderSibling]) -> [String] {
    PlaylistFolderOrdering.sorted(siblings).map(\.name)
  }

  // MARK: - Comparator

  func testOrdersBySortOrderAscending() {
    let siblings = [
      folderSibling("Third", sortOrder: 30),
      folderSibling("First", sortOrder: 10),
      folderSibling("Second", sortOrder: 20),
    ]
    XCTAssertEqual(sortedNames(siblings), ["First", "Second", "Third"])
  }

  func testTiesOnSortOrderBreakByName() {
    let siblings = [
      folderSibling("Zebra", sortOrder: 10),
      folderSibling("Apple", sortOrder: 10),
      folderSibling("Mango", sortOrder: 10),
    ]
    XCTAssertEqual(sortedNames(siblings), ["Apple", "Mango", "Zebra"])
  }

  func testUnorderedSiblingsSortAfterOrderedOnes() {
    let siblings = [
      folderSibling("NoOrderApple", sortOrder: nil),
      folderSibling("Ordered", sortOrder: 500),
      folderSibling("NoOrderZebra", sortOrder: nil),
    ]
    XCTAssertEqual(
      sortedNames(siblings),
      ["Ordered", "NoOrderApple", "NoOrderZebra"]
    )
  }

  /// A negative sortOrder is legal — inserting before the current head produces
  /// one — and must still sort ahead of everything, not be treated as unset.
  func testNegativeSortOrderStillSortsBeforeUnordered() {
    let siblings = [
      folderSibling("Unordered", sortOrder: nil),
      folderSibling("Negative", sortOrder: -10),
      folderSibling("Zero", sortOrder: 0),
    ]
    XCTAssertEqual(sortedNames(siblings), ["Negative", "Zero", "Unordered"])
  }

  /// Folders and playlists are one ordering space, not two — a playlist can sit
  /// between two folders.
  func testFoldersAndPlaylistsInterleaveInOneSpace() {
    let siblings = [
      folderSibling("FolderLate", sortOrder: 30),
      playlistSibling("PlaylistMiddle", sortOrder: 20),
      folderSibling("FolderEarly", sortOrder: 10),
    ]
    XCTAssertEqual(
      sortedNames(siblings),
      ["FolderEarly", "PlaylistMiddle", "FolderLate"]
    )
  }

  /// Two siblings can share both a sortOrder and a name; the comparator must
  /// still be a strict weak ordering rather than an unstable coin flip.
  func testIdenticalSortOrderAndNameFallsBackToId() {
    let firstSibling = PlaylistFolderSibling(
      kind: .folder, id: "aaa", name: "Same", sortOrder: 10
    )
    let secondSibling = PlaylistFolderSibling(
      kind: .folder, id: "bbb", name: "Same", sortOrder: 10
    )
    XCTAssertTrue(PlaylistFolderOrdering.isOrderedBefore(firstSibling, secondSibling))
    XCTAssertFalse(PlaylistFolderOrdering.isOrderedBefore(secondSibling, firstSibling))
  }

  func testEmptySiblingListSortsToEmpty() {
    XCTAssertTrue(PlaylistFolderOrdering.sorted([]).isEmpty)
  }

  // MARK: - Append

  func testAppendIntoEmptyParentTakesFirstGap() {
    XCTAssertEqual(
      PlaylistFolderOrdering.appendSortOrder(after: []),
      PlaylistFolderOrdering.sortOrderGap
    )
  }

  func testAppendTakesHighestSortOrderPlusOneGap() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 40),
      folderSibling("C", sortOrder: 20),
    ]
    XCTAssertEqual(PlaylistFolderOrdering.appendSortOrder(after: siblings), 50)
  }

  /// Only ordered siblings can raise the ceiling; an unordered tail must not
  /// reset the append point back to the first gap.
  func testAppendIgnoresUnorderedSiblings() {
    let siblings = [
      folderSibling("Ordered", sortOrder: 70),
      folderSibling("Unordered", sortOrder: nil),
    ]
    XCTAssertEqual(PlaylistFolderOrdering.appendSortOrder(after: siblings), 80)
  }

  // MARK: - Insertion: gap available

  func testInsertBetweenSpacedNeighboursTakesMidpointWithoutRenumbering() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 20),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)
    XCTAssertEqual(plan, .assign(sortOrder: 15))
  }

  func testInsertAtHeadStepsAGapBelowTheCurrentFirst() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 20),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 0)
    XCTAssertEqual(plan, .assign(sortOrder: 0))
  }

  func testInsertAtTailAppendsAGapAboveTheCurrentLast() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 20),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 2)
    XCTAssertEqual(plan, .assign(sortOrder: 30))
  }

  func testInsertIntoEmptyParentTakesFirstGap() {
    let plan = PlaylistFolderOrdering.insertionPlan(into: [], targetIndex: 0)
    XCTAssertEqual(plan, .assign(sortOrder: PlaylistFolderOrdering.sortOrderGap))
  }

  /// Appending past an unordered tail needs no renumber: the tail already sorts
  /// after every ordered sibling.
  func testInsertAfterLastOrderedSiblingDoesNotRenumber() {
    let siblings = [
      folderSibling("Ordered", sortOrder: 10),
      folderSibling("Unordered", sortOrder: nil),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)
    XCTAssertEqual(plan, .assign(sortOrder: 20))
  }

  // MARK: - Insertion: no gap left

  func testInsertBetweenAdjacentIntegersRenumbersSiblings() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 11),
      folderSibling("C", sortOrder: 12),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)

    guard case let .renumberSiblings(assignments, insertedSortOrder) = plan else {
      return XCTFail("Expected a renumber, got \(plan)")
    }
    // Slot 1 goes to the incoming item, so A keeps 10 and B/C shift up.
    XCTAssertEqual(insertedSortOrder, 20)
    XCTAssertEqual(
      assignments,
      [
        PlaylistFolderSortOrderAssignment(kind: .folder, id: "folder-B", sortOrder: 30),
        PlaylistFolderSortOrderAssignment(kind: .folder, id: "folder-C", sortOrder: 40),
      ]
    )
  }

  /// Duplicate sortOrders are explicitly legal in the contract, so they must be
  /// handled rather than assumed away — there is no midpoint between them.
  func testInsertBetweenDuplicateSortOrdersRenumbersSiblings() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 10),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)
    guard case .renumberSiblings = plan else {
      return XCTFail("Expected a renumber, got \(plan)")
    }
  }

  /// Inserting into the unordered tail has no anchor to compute a midpoint
  /// against, so the siblings get numbers for the first time.
  func testInsertAmongUnorderedSiblingsRenumbersThem() {
    let siblings = [
      folderSibling("A", sortOrder: nil),
      folderSibling("B", sortOrder: nil),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)

    guard case let .renumberSiblings(assignments, insertedSortOrder) = plan else {
      return XCTFail("Expected a renumber, got \(plan)")
    }
    XCTAssertEqual(insertedSortOrder, 20)
    XCTAssertEqual(assignments.count, 2)
  }

  /// A renumber must only report siblings whose value actually changes, so the
  /// client issues the fewest update requests it can.
  func testRenumberOnlyReportsSiblingsWhoseSortOrderChanges() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 11),
    ]
    // No midpoint between 10 and 11, so the pair is renumbered onto a fresh gap
    // scale: A stays on 10, the incoming item takes 20 and B moves to 30. A is
    // already correct, so it must not be reported as needing an update.
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 1)
    guard case let .renumberSiblings(assignments, insertedSortOrder) = plan else {
      return XCTFail("Expected a renumber, got \(plan)")
    }
    XCTAssertEqual(insertedSortOrder, 20)
    XCTAssertEqual(
      assignments,
      [PlaylistFolderSortOrderAssignment(kind: .folder, id: "folder-B", sortOrder: 30)]
    )
  }

  /// Appending past the last ordered sibling always has room, so it must never
  /// pay the cost of a renumber even when the existing values are packed tight.
  func testAppendingAfterTightlyPackedSiblingsStillAssignsWithoutRenumbering() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 11),
    ]
    let plan = PlaylistFolderOrdering.insertionPlan(into: siblings, targetIndex: 2)
    XCTAssertEqual(plan, .assign(sortOrder: 21))
  }

  /// Whatever the plan, applying it must actually put the item where it was
  /// asked to go.
  func testPlannedSortOrderLandsTheItemAtTheRequestedIndex() {
    let siblings = [
      folderSibling("A", sortOrder: 10),
      folderSibling("B", sortOrder: 11),
      folderSibling("C", sortOrder: 12),
    ]
    for targetIndex in 0 ... siblings.count {
      let plan = PlaylistFolderOrdering.insertionPlan(
        into: siblings, targetIndex: targetIndex
      )
      var resultingSiblings: [PlaylistFolderSibling]
      let insertedSortOrder: Int
      switch plan {
      case let .assign(sortOrder):
        resultingSiblings = siblings
        insertedSortOrder = sortOrder
      case let .renumberSiblings(assignments, newSortOrder):
        var assignedSortOrders = [String: Int]()
        for assignment in assignments { assignedSortOrders[assignment.id] = assignment.sortOrder }
        resultingSiblings = siblings.map { sibling in
          PlaylistFolderSibling(
            kind: sibling.kind,
            id: sibling.id,
            name: sibling.name,
            sortOrder: assignedSortOrders[sibling.id] ?? sibling.sortOrder
          )
        }
        insertedSortOrder = newSortOrder
      }
      resultingSiblings.append(PlaylistFolderSibling(
        kind: .folder, id: "folder-Inserted", name: "Inserted", sortOrder: insertedSortOrder
      ))

      let landedIndex = PlaylistFolderOrdering.sorted(resultingSiblings)
        .firstIndex { $0.id == "folder-Inserted" }
      XCTAssertEqual(
        landedIndex, targetIndex,
        "Item planned for index \(targetIndex) landed at \(String(describing: landedIndex))"
      )
    }
  }

  // MARK: - Root id normalization

  func testRootIdNormalizesEveryServerSpelling() {
    XCTAssertEqual(PlaylistFolderRootId.normalized(nil), "")
    XCTAssertEqual(PlaylistFolderRootId.normalized(""), "")
    XCTAssertEqual(PlaylistFolderRootId.normalized("root"), "")
    XCTAssertEqual(PlaylistFolderRootId.normalized("folder-1"), "folder-1")
    XCTAssertTrue(PlaylistFolderRootId.isRoot("root"))
    XCTAssertFalse(PlaylistFolderRootId.isRoot("folder-1"))
  }
}
