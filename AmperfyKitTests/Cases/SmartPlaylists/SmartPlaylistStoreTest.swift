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

  // MARK: - V1 → V1.5 migration

  /// A VERBATIM state blob as build 83 wrote it: the query is the flat
  /// `{"rules": [...]}` shape with an implicit AND and no `combinator`/`items`
  /// keys, and every rule carries Swift's synthesised enum encoding.
  ///
  /// This string is the contract. It must never be regenerated from the current
  /// types — if a change to `SmartPlaylistRule` breaks this test, it has broken
  /// shipped users' persisted queries.
  static let version1StateBlob = """
  {
    "query": {
      "rules": [
        {"addedWithinDays": {"_0": 14}},
        {"played": {"_0": {"notInLastDays": {"_0": 90}}}},
        {"played": {"_0": {"never": {}}}},
        {"playlistCount": {"comparison": "fewerThan", "count": 2}},
        {"notInPlaylist": {"playlistId": "pl-done", "name": "Done"}},
        {"inPlaylist": {"playlistId": "pl-inbox", "name": "Inbox"}}
      ]
    },
    "frozenSongIds": ["a", "b", "c"],
    "refreshedAt": "2025-06-15T15:06:40Z",
    "wasOfflineRefresh": true,
    "songsMissingAddedDate": 7
  }
  """

  /// The whole point of the V1.5 Codable work: a build-83 blob sitting in a
  /// shipped user's `UserDefaults` must still load, as a top-level `.all`
  /// container of bare rules — same rules, same order, same frozen result.
  func testDecodesVersion1FlatQueryBlob() throws {
    defaults.set(
      Data(Self.version1StateBlob.utf8),
      forKey: "amperfy.fork.smartPlaylists.currentState"
    )

    let loaded = try XCTUnwrap(store.loadCurrentState())
    XCTAssertEqual(loaded.query.combinator, .all)
    XCTAssertEqual(loaded.query.items.count, 6)
    XCTAssertEqual(loaded.query.allRules, [
      .addedWithinDays(14),
      .played(.notInLastDays(90)),
      .played(.never),
      .playlistCount(comparison: .fewerThan, count: 2),
      .notInPlaylist(playlistId: "pl-done", name: "Done"),
      .inPlaylist(playlistId: "pl-inbox", name: "Inbox"),
    ])
    // Every item is a bare rule — the migration never invents a group.
    XCTAssertTrue(loaded.query.items.allSatisfy { $0.asRule != nil })
    XCTAssertEqual(loaded.frozenSongIds, ["a", "b", "c"])
    XCTAssertEqual(loaded.refreshedAt, refreshInstant)
    XCTAssertTrue(loaded.wasOfflineRefresh)
    XCTAssertEqual(loaded.songsMissingAddedDate, 7)
  }

  /// A V1 blob with an empty rule list is the "All songs" query, not a decode
  /// failure.
  func testDecodesVersion1BlobWithNoRules() throws {
    let emptyRulesBlob = """
    {"query": {"rules": []}, "frozenSongIds": [], "refreshedAt": "2025-06-15T15:06:40Z", \
    "wasOfflineRefresh": false, "songsMissingAddedDate": 0}
    """
    defaults.set(
      Data(emptyRulesBlob.utf8),
      forKey: "amperfy.fork.smartPlaylists.currentState"
    )

    let loaded = try XCTUnwrap(store.loadCurrentState())
    XCTAssertTrue(loaded.query.isEmpty)
    XCTAssertEqual(loaded.query.summaryText, "All songs")
  }

  /// Re-saving a migrated state writes the NEW shape, so the upgrade is a
  /// one-way door taken on the user's next refresh.
  func testResavingAMigratedStateWritesTheGroupedFormat() throws {
    defaults.set(
      Data(Self.version1StateBlob.utf8),
      forKey: "amperfy.fork.smartPlaylists.currentState"
    )
    let migrated = try XCTUnwrap(store.loadCurrentState())
    store.save(migrated)

    let rewritten = try XCTUnwrap(defaults.data(forKey: "amperfy.fork.smartPlaylists.currentState"))
    let rewrittenJson = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
    XCTAssertTrue(rewrittenJson.contains("\"items\""))
    XCTAssertTrue(rewrittenJson.contains("\"combinator\""))
    XCTAssertEqual(store.loadCurrentState(), migrated)
  }

  /// A grouped query survives the round trip intact, groups and combinators
  /// included.
  func testGroupedQueryRoundTrips() throws {
    let groupedQuery = SmartPlaylistQuery(
      combinator: .all,
      items: [
        .rule(.addedWithinDays(30)),
        .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
          .played(.never),
          .completeAlbum(isComplete: true),
        ])),
      ]
    )
    let state = SmartPlaylistState(
      query: groupedQuery,
      frozenSongIds: ["x"],
      refreshedAt: refreshInstant,
      wasOfflineRefresh: false,
      songsMissingAddedDate: 0
    )
    store.save(state)

    XCTAssertEqual(SmartPlaylistStore(defaults: defaults).loadCurrentState(), state)
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

  /// The summary line the results header renders — a flat AND query reads as a
  /// plain "and" list.
  func testQuerySummaryTextJoinsRulesWithTheTopLevelConjunction() {
    let query = SmartPlaylistQuery(rules: [
      .addedWithinDays(30),
      .played(.never),
      .notInPlaylist(playlistId: "pl-done", name: "Done"),
    ])
    XCTAssertEqual(
      query.summaryText,
      "Added in the last 30 days and Never played and Not in \"Done\""
    )
  }

  /// The addendum's worked example: groups are parenthesised, the top level
  /// keeps its own conjunction.
  func testQuerySummaryTextParenthesisesGroups() {
    let query = SmartPlaylistQuery(items: [
      .rule(.addedWithinDays(30)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .played(.never),
        .playlistCount(comparison: .fewerThan, count: 2),
      ])),
    ])
    XCTAssertEqual(
      query.summaryText,
      "Added in the last 30 days and (Never played or In fewer than 2 playlists)"
    )
  }

  /// An `.any` top level says "or" between its items.
  func testQuerySummaryTextUsesOrForAnyTopLevel() {
    let query = SmartPlaylistQuery(
      combinator: .any,
      items: [.rule(.played(.never)), .rule(.completeAlbum(isComplete: false))]
    )
    XCTAssertEqual(query.summaryText, "Never played or Not part of a complete album")
  }

  /// Parentheses around one condition carry no information, so a one-rule group
  /// reads as the bare rule. Empty groups say nothing and are skipped.
  func testQuerySummaryTextSkipsParensForSingleRuleGroupsAndDropsEmptyOnes() {
    let singleRuleGroupQuery = SmartPlaylistQuery(items: [
      .rule(.played(.never)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [.completeAlbum(isComplete: true)])),
    ])
    XCTAssertEqual(
      singleRuleGroupQuery.summaryText,
      "Never played and Part of a complete album"
    )

    let emptyGroupQuery = SmartPlaylistQuery(items: [
      .rule(.played(.never)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [])),
    ])
    XCTAssertEqual(emptyGroupQuery.summaryText, "Never played")
  }

  func testEmptyQuerySummaryReadsAsAllSongs() {
    XCTAssertEqual(SmartPlaylistQuery().summaryText, "All songs")
  }

  /// The builder drops groups the user emptied before the query is persisted.
  func testRemoveEmptyGroupsDropsOnlyEmptyGroups() {
    var query = SmartPlaylistQuery(items: [
      .rule(.played(.never)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [])),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [.completeAlbum(isComplete: true)])),
    ])
    query.removeEmptyGroups()
    XCTAssertEqual(query.items.count, 2)
    XCTAssertEqual(query.allRules, [.played(.never), .completeAlbum(isComplete: true)])
  }

  /// The flat `rules` view reaches into groups, so anything reading it sees the
  /// whole query rather than only its top level.
  func testFlatRulesViewIncludesGroupedRules() {
    let query = SmartPlaylistQuery(items: [
      .rule(.addedWithinDays(30)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .played(.never),
        .completeAlbum(isComplete: true),
      ])),
    ])
    XCTAssertEqual(query.rules, [
      .addedWithinDays(30),
      .played(.never),
      .completeAlbum(isComplete: true),
    ])
    XCTAssertFalse(query.isEmpty)
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
    XCTAssertTrue(query.canAddRule(ofKind: .completeAlbum))
    XCTAssertTrue(query.canAddRule(ofKind: .inPlaylist))
    XCTAssertTrue(query.canAddRule(ofKind: .notInPlaylist))
  }

  /// Repeatability is decided PER CONTAINER, which is what keeps
  /// "is complete OR added recently" expressible: a group may hold its own
  /// instance of a kind the top level has already used.
  func testRuleRepeatabilityIsScopedToItsContainer() {
    let query = SmartPlaylistQuery(items: [
      .rule(.completeAlbum(isComplete: true)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [.played(.never)])),
    ])
    XCTAssertFalse(query.canAddRule(ofKind: .completeAlbum))
    XCTAssertTrue(query.canAddRule(ofKind: .completeAlbum, toGroupAt: 1))
    XCTAssertFalse(query.canAddRule(ofKind: .played, toGroupAt: 1))
    // Index 0 is a bare rule, not a group.
    XCTAssertFalse(query.canAddRule(ofKind: .played, toGroupAt: 0))
  }

  /// `requiresAlbumData` gates the candidate fetch's `album` prefetch.
  func testRequiresAlbumDataOnlyForCompleteAlbumRules() {
    XCTAssertFalse(SmartPlaylistQuery(rules: [.played(.never)]).requiresAlbumData)
    XCTAssertTrue(
      SmartPlaylistQuery(items: [
        .group(SmartPlaylistRuleGroup(rules: [.completeAlbum(isComplete: true)])),
      ]).requiresAlbumData
    )
  }
}
