//
//  SmartPlaylistStoreTest.swift
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

/// Round-trip tests for the frozen smart playlist state, over an injected
/// `UserDefaults` suite so nothing leaks into the real defaults.
@MainActor
class SmartPlaylistStoreTest: XCTestCase {
  var defaults: UserDefaults!
  var store: SmartPlaylistStore!
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var otherAccount: Account!

  let refreshInstant = Date(timeIntervalSince1970: 1_750_000_000)

  override func setUp() async throws {
    defaults = UserDefaults(suiteName: "SmartPlaylistStoreTest-\(UUID().uuidString)")
    store = SmartPlaylistStore(defaults: defaults)
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    otherAccount = library.getAccount(info: TestAccountInfo.create2())
  }

  override func tearDown() {}

  // MARK: - Helpers

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  private func makeState(
    rules: [SmartPlaylistRule] = [.addedWithinDays(30), .played(.never)],
    frozenSongIds: [String] = ["song-1", "song-2"],
    wasOfflineRefresh: Bool = false,
    songsMissingAddedDate: Int = 0
  )
    -> SmartPlaylistState {
    SmartPlaylistState(
      query: SmartPlaylistQuery(rules: rules),
      frozenSongIds: frozenSongIds,
      refreshedAt: refreshInstant,
      wasOfflineRefresh: wasOfflineRefresh,
      songsMissingAddedDate: songsMissingAddedDate
    )
  }

  @discardableResult
  private func makeSong(id: String, ownedBy owner: Account? = nil) -> Song {
    let song = library.createSong(account: owner ?? account)
    song.id = id
    song.title = id
    song.size = 1024
    return song
  }

  // MARK: - Empty state

  func testLoadsNilBeforeAnythingIsSaved() {
    XCTAssertNil(store.loadCurrentState())
    XCTAssertFalse(store.hasStoredState)
  }

  // MARK: - Round trip

  func testSavedStateRoundTripsThroughAFreshInstance() {
    let state = makeState(
      rules: [
        .addedWithinDays(14),
        .played(.notInLastDays(90)),
        .playlistCount(comparison: .fewerThan, count: 2),
        .notInPlaylist(playlistId: "pl-done", name: "Done"),
        .inPlaylist(playlistId: "pl-inbox", name: "Inbox"),
      ],
      frozenSongIds: ["a", "b", "c"],
      wasOfflineRefresh: true,
      songsMissingAddedDate: 7
    )
    store.save(state)

    let reloaded = SmartPlaylistStore(defaults: defaults).loadCurrentState()
    XCTAssertEqual(reloaded, state)
  }

  /// Result order is part of the payload — the frozen list is presented in
  /// exactly the order it was generated in.
  func testFrozenIdOrderIsPreserved() {
    store.save(makeState(frozenSongIds: ["z", "a", "m"]))
    XCTAssertEqual(store.loadCurrentState()?.frozenSongIds, ["z", "a", "m"])
  }

  func testSavingAgainReplacesThePreviousState() {
    store.save(makeState(frozenSongIds: ["first"]))
    store.save(makeState(frozenSongIds: ["second"]))
    XCTAssertEqual(store.loadCurrentState()?.frozenSongIds, ["second"])
  }

  func testClearRemovesTheStoredState() {
    store.save(makeState())
    XCTAssertTrue(store.hasStoredState)
    store.clear()
    XCTAssertFalse(store.hasStoredState)
    XCTAssertNil(store.loadCurrentState())
  }

  /// The persisted key is fork-namespaced so it can never collide with an
  /// upstream Amperfy default.
  func testUsesForkNamespacedKey() {
    store.save(makeState())
    XCTAssertNotNil(defaults.data(forKey: "amperfy.fork.smartPlaylists.currentState"))
  }

  /// An undecodable blob (e.g. written by a future rule model) reads as "no
  /// state" rather than crashing the results screen.
  func testUndecodableBlobReadsAsNoState() {
    defaults.set(Data("not json".utf8), forKey: "amperfy.fork.smartPlaylists.currentState")
    XCTAssertNil(store.loadCurrentState())
  }

  // MARK: - Rehydration

  func testResolveSongsReturnsSongsInStoredOrder() {
    makeSong(id: "song-a")
    makeSong(id: "song-b")
    makeSong(id: "song-c")
    library.saveContext()

    let resolved = store.resolveSongs(
      forIds: ["song-c", "song-a", "song-b"],
      context: testContext,
      account: account
    )
    XCTAssertEqual(resolved.map { $0.id }, ["song-c", "song-a", "song-b"])
  }

  /// A frozen list must degrade quietly: ids that no longer resolve are
  /// dropped, the rest keep their order.
  func testResolveSongsDropsMissingIdsSilently() {
    makeSong(id: "song-a")
    makeSong(id: "song-c")
    library.saveContext()

    let resolved = store.resolveSongs(
      forIds: ["song-a", "song-gone", "song-c"],
      context: testContext,
      account: account
    )
    XCTAssertEqual(resolved.map { $0.id }, ["song-a", "song-c"])
  }

  func testResolveSongsIsAccountScoped() {
    makeSong(id: "song-mine")
    makeSong(id: "song-theirs", ownedBy: otherAccount)
    library.saveContext()

    let resolved = store.resolveSongs(
      forIds: ["song-mine", "song-theirs"],
      context: testContext,
      account: account
    )
    XCTAssertEqual(resolved.map { $0.id }, ["song-mine"])
  }

  func testResolveSongsForStateUsesItsFrozenIds() {
    makeSong(id: "song-a")
    makeSong(id: "song-b")
    library.saveContext()

    let state = makeState(frozenSongIds: ["song-b", "song-a"])
    let resolved = store.resolveSongs(for: state, context: testContext, account: account)
    XCTAssertEqual(resolved.map { $0.id }, ["song-b", "song-a"])
  }

  func testResolveSongsWithNoIdsReturnsEmpty() {
    XCTAssertTrue(
      store.resolveSongs(forIds: [], context: testContext, account: account).isEmpty
    )
  }

  // MARK: - Query model

  /// The summary line the results header renders.
  func testQuerySummaryTextListsEveryRule() {
    let query = SmartPlaylistQuery(rules: [
      .addedWithinDays(30),
      .played(.never),
      .notInPlaylist(playlistId: "pl-done", name: "Done"),
    ])
    XCTAssertEqual(
      query.summaryText,
      "Added in the last 30 days · Never played · Not in \"Done\""
    )
  }

  func testEmptyQuerySummaryReadsAsAllSongs() {
    XCTAssertEqual(SmartPlaylistQuery().summaryText, "All songs")
  }

  /// The refresher reads this to decide whether a newest-albums backfill is
  /// needed; the widest window wins.
  func testAddedWithinDaysReportsTheWidestWindow() {
    XCTAssertNil(SmartPlaylistQuery(rules: [.played(.never)]).addedWithinDays)
    XCTAssertEqual(
      SmartPlaylistQuery(rules: [.addedWithinDays(7), .addedWithinDays(30)]).addedWithinDays,
      30
    )
  }

  /// Drives the "sync unsynced playlists first" step.
  func testRequiresPlaylistItemsOnlyForMembershipRules() {
    XCTAssertFalse(
      SmartPlaylistQuery(rules: [.addedWithinDays(7), .played(.never)]).requiresPlaylistItems
    )
    XCTAssertTrue(
      SmartPlaylistQuery(rules: [.inPlaylist(playlistId: "p", name: "P")]).requiresPlaylistItems
    )
    XCTAssertTrue(
      SmartPlaylistQuery(rules: [.playlistCount(comparison: .moreThan, count: 1)])
        .requiresPlaylistItems
    )
  }

  /// Playlist rules may repeat (several "not in X" rules are meaningful); the
  /// others may not.
  func testRuleRepeatabilityPolicy() {
    let query = SmartPlaylistQuery(rules: [
      .addedWithinDays(7),
      .inPlaylist(playlistId: "p", name: "P"),
    ])
    XCTAssertFalse(query.canAddRule(ofKind: .addedWithinDays))
    XCTAssertTrue(query.canAddRule(ofKind: .played))
    XCTAssertTrue(query.canAddRule(ofKind: .inPlaylist))
    XCTAssertTrue(query.canAddRule(ofKind: .notInPlaylist))
  }
}
