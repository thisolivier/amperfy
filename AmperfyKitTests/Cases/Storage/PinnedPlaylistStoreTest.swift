//
//  PinnedPlaylistStoreTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (Feature D — Favourites).
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

/// Unit tests for `PinnedPlaylistStore` (Feature D — local-only favourites).
@MainActor
class PinnedPlaylistStoreTest: XCTestCase {
  private var suiteName: String!
  private var testDefaults: UserDefaults!
  private var store: PinnedPlaylistStore!

  override func setUp() {
    super.setUp()
    suiteName = "PinnedPlaylistStoreTest.\(UUID().uuidString)"
    testDefaults = UserDefaults(suiteName: suiteName)!
    store = PinnedPlaylistStore(defaults: testDefaults)
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  // MARK: - Tests

  /// Fresh store has no pinned playlists.
  func testEmptyStateReturnsNoPins() {
    XCTAssertTrue(store.pinnedIds.isEmpty)
    XCTAssertFalse(store.isPinned("any-id"))
  }

  /// Pinning a playlist adds it to the set.
  func testPinAddsId() {
    store.pin("playlist-1")
    XCTAssertTrue(store.isPinned("playlist-1"))
    XCTAssertEqual(store.pinnedIds, ["playlist-1"])
  }

  /// Unpinning a playlist removes it from the set.
  func testUnpinRemovesId() {
    store.pin("playlist-1")
    store.unpin("playlist-1")
    XCTAssertFalse(store.isPinned("playlist-1"))
    XCTAssertTrue(store.pinnedIds.isEmpty)
  }

  /// Toggle flips the state and returns the new value.
  func testToggleFlipsState() {
    let firstResult = store.toggle("playlist-2")
    XCTAssertTrue(firstResult, "First toggle should pin (return true)")
    XCTAssertTrue(store.isPinned("playlist-2"))

    let secondResult = store.toggle("playlist-2")
    XCTAssertFalse(secondResult, "Second toggle should unpin (return false)")
    XCTAssertFalse(store.isPinned("playlist-2"))
  }

  /// Pinned state persists across store instances using the same UserDefaults suite.
  func testPersistenceAcrossInstances() {
    store.pin("playlist-persist")
    let secondStore = PinnedPlaylistStore(defaults: testDefaults)
    XCTAssertTrue(secondStore.isPinned("playlist-persist"))
  }

  /// Mutation fires the didChangeNotification.
  func testNotificationFiresOnMutation() {
    let expectation = expectation(description: "didChangeNotification fires")
    let observer = NotificationCenter.default.addObserver(
      forName: PinnedPlaylistStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      expectation.fulfill()
    }
    store.pin("notif-test")
    waitForExpectations(timeout: 2)
    NotificationCenter.default.removeObserver(observer)
  }
}
