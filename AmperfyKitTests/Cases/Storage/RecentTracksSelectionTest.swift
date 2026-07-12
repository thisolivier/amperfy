//
//  RecentTracksSelectionTest.swift
//  AmperfyKitTests
//
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

/// Unit tests for `RecentTracksSelection`, the id-keyed bulk-select model for
/// the Recently Added detail screen. UIKit-free, so no simulator table is
/// needed — we seed real `Song` wrappers over an in-memory store and drive the
/// model directly.
@MainActor
class RecentTracksSelectionTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var selection: RecentTracksSelection!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    selection = RecentTracksSelection()
  }

  override func tearDown() {}

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  func testStartsEmpty() {
    XCTAssertTrue(selection.isEmpty)
    XCTAssertEqual(selection.count, 0)
    XCTAssertFalse(selection.isSelected(songId: "t-1"))
  }

  func testSelectAndCount() {
    selection.select(songId: "t-1")
    selection.select(songId: "t-2")
    XCTAssertFalse(selection.isEmpty)
    XCTAssertEqual(selection.count, 2)
    XCTAssertTrue(selection.isSelected(songId: "t-1"))
    XCTAssertTrue(selection.isSelected(songId: "t-2"))
  }

  func testSelectIsIdempotent() {
    selection.select(songId: "t-1")
    selection.select(songId: "t-1")
    XCTAssertEqual(selection.count, 1)
  }

  func testDeselect() {
    selection.select(songId: "t-1")
    selection.deselect(songId: "t-1")
    XCTAssertTrue(selection.isEmpty)
    XCTAssertFalse(selection.isSelected(songId: "t-1"))
  }

  func testToggleReturnsNewState() {
    XCTAssertTrue(selection.toggle(songId: "t-1"), "first toggle selects")
    XCTAssertTrue(selection.isSelected(songId: "t-1"))
    XCTAssertFalse(selection.toggle(songId: "t-1"), "second toggle deselects")
    XCTAssertFalse(selection.isSelected(songId: "t-1"))
  }

  func testClearDropsEverything() {
    selection.select(songId: "t-1")
    selection.select(songId: "t-2")
    selection.clear()
    XCTAssertTrue(selection.isEmpty)
  }

  /// Selection resolves to concrete songs in LIST order, not set order.
  func testSelectedSongsPreservesListOrder() {
    let s1 = makeSong(id: "t-1")
    let s2 = makeSong(id: "t-2")
    let s3 = makeSong(id: "t-3")
    let ordered = [s1, s2, s3]
    // Select in a different order than the list.
    selection.select(songId: "t-3")
    selection.select(songId: "t-1")

    let resolved = selection.selectedSongs(from: ordered)
    XCTAssertEqual(
      resolved.map(\.id),
      ["t-1", "t-3"],
      "resolved in list order, not selection order"
    )
  }

  func testSelectedSongsIgnoresIdsNotInList() {
    let s1 = makeSong(id: "t-1")
    selection.select(songId: "t-1")
    selection.select(songId: "t-ghost") // never in the list

    let resolved = selection.selectedSongs(from: [s1])
    XCTAssertEqual(resolved.map(\.id), ["t-1"])
  }

  /// The live-refresh reconciliation: after the list drops a filed track,
  /// `retainOnly` prunes the vanished selection so the count and resolution
  /// stay honest. This is the item-1 + item-2 interaction: adding to a
  /// playlist makes filtered tracks disappear live.
  func testRetainOnlyPrunesVanishedSelection() {
    let s1 = makeSong(id: "t-1")
    let s2 = makeSong(id: "t-2")
    selection.select(songId: "t-1")
    selection.select(songId: "t-2")
    XCTAssertEqual(selection.count, 2)

    // t-2 was just filed and is now hidden by the triage filter — the visible
    // list only contains t-1.
    selection.retainOnly(visibleSongs: [s1])

    XCTAssertEqual(selection.count, 1)
    XCTAssertTrue(selection.isSelected(songId: "t-1"))
    XCTAssertFalse(selection.isSelected(songId: "t-2"))
    _ = s2 // silence unused warning; kept for symmetry/readability
  }

  func testRetainOnlyWithEmptyVisibleClearsAll() {
    selection.select(songId: "t-1")
    selection.retainOnly(visibleSongs: [])
    XCTAssertTrue(selection.isEmpty)
  }
}
