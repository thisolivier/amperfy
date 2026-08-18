//
//  SmartPlaylistQueryEngineTest.swift
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

/// Unit tests for `SmartPlaylistQueryEngine`: one case per rule type, the
/// AND-combination behaviour, the always-on guards (playable + account scoping),
/// and the two "honest caveat" outputs (missing-added-date count, dropped
/// playlist rules).
///
/// Every seeded song sets `size > 0` and hangs off an album with the default
/// `.available` remote status so it satisfies
/// `SongMO.excludeServerDeleteUncachedSongsFetchPredicate`.
@MainActor
class SmartPlaylistQueryEngineTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var otherAccount: Account!
  var hostAlbum: Album!

  /// Fixed reference "now" so every relative-date assertion is deterministic.
  let nowReference = Date(timeIntervalSince1970: 1_750_000_000)
  let dayInSeconds = 86_400.0

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    otherAccount = library.getAccount(info: TestAccountInfo.create2())
    // The shared seeder inserts playables of its own; the engine's counts are
    // absolute (not prefix-filtered), so start from a clean song table.
    removeAllSongs()
    hostAlbum = library.createAlbum(account: account)
    hostAlbum.id = "spq-album"
    library.saveContext()
  }

  override func tearDown() {}

  // MARK: - Helpers

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  private func removeAllSongs() {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    for song in (try? testContext.fetch(fetchRequest)) ?? [] {
      testContext.delete(song)
    }
    library.saveContext()
  }

  @discardableResult
  private func makeSong(
    id: String,
    addedDaysAgo: Double? = nil,
    playCount: Int = 0,
    lastPlayedDaysAgo: Double? = nil,
    ownedBy owner: Account? = nil
  )
    -> Song {
    let song = library.createSong(account: owner ?? account)
    song.id = id
    song.title = id
    song.size = 1024
    song.album = hostAlbum
    if let addedDaysAgo {
      song.addedDate = nowReference.addingTimeInterval(-addedDaysAgo * dayInSeconds)
    }
    song.playCount = playCount
    if let lastPlayedDaysAgo {
      song.lastTimePlayed = nowReference.addingTimeInterval(-lastPlayedDaysAgo * dayInSeconds)
    }
    return song
  }

  @discardableResult
  private func makePlaylist(
    id: String,
    name: String,
    ownedBy owner: Account? = nil
  )
    -> Playlist {
    let playlist = library.createPlaylist(account: owner ?? account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  private func evaluate(_ rules: [SmartPlaylistRule]) -> SmartPlaylistEvaluation {
    SmartPlaylistQueryEngine.evaluate(
      query: SmartPlaylistQuery(rules: rules),
      context: testContext,
      account: account,
      now: nowReference
    )
  }

  private func matchedIds(_ rules: [SmartPlaylistRule]) -> [String] {
    evaluate(rules).songs.map { $0.id }
  }

  // MARK: - Rule: addedWithinDays

  func testAddedWithinDaysMatchesOnlySongsInsideWindow() {
    makeSong(id: "s-2d", addedDaysAgo: 2)
    makeSong(id: "s-6d", addedDaysAgo: 6)
    makeSong(id: "s-30d", addedDaysAgo: 30)
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(7)]), ["s-2d", "s-6d"])
  }

  /// A song whose added-date is unknown never matches an added-within rule —
  /// we must not guess that "no date" means "recent".
  func testAddedWithinDaysExcludesSongsWithoutAddedDate() {
    makeSong(id: "s-known", addedDaysAgo: 1)
    makeSong(id: "s-unknown")
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(7)]), ["s-known"])
  }

  /// Excluded-but-counted: the footer note needs the number of songs the
  /// library simply has no added-date for.
  func testMissingAddedDateCountIsReportedWhenRuleIsActive() {
    makeSong(id: "s-known", addedDaysAgo: 1)
    makeSong(id: "s-unknown-a")
    makeSong(id: "s-unknown-b")
    library.saveContext()

    XCTAssertEqual(evaluate([.addedWithinDays(7)]).songsMissingAddedDate, 2)
  }

  /// Without an added-within rule a missing date excludes nothing, so the
  /// count stays zero rather than showing an irrelevant note.
  func testMissingAddedDateCountIsZeroWithoutAddedWithinRule() {
    makeSong(id: "s-unknown-a")
    makeSong(id: "s-unknown-b")
    library.saveContext()

    XCTAssertEqual(evaluate([.played(.never)]).songsMissingAddedDate, 0)
  }

  /// The missing-added-date count respects the query's OTHER rules: a song
  /// that would fail on play history anyway is not part of the "we just don't
  /// know" population.
  func testMissingAddedDateCountHonoursOtherRules() {
    makeSong(id: "s-unknown-unplayed", playCount: 0)
    makeSong(id: "s-unknown-played", playCount: 4)
    library.saveContext()

    let evaluation = evaluate([.addedWithinDays(7), .played(.never)])
    XCTAssertEqual(evaluation.songsMissingAddedDate, 1)
  }

  // MARK: - Rule: played

  func testPlayedNeverMatchesOnlyZeroPlayCount() {
    makeSong(id: "s-never", playCount: 0)
    makeSong(id: "s-once", playCount: 1)
    library.saveContext()

    XCTAssertEqual(matchedIds([.played(.never)]), ["s-never"])
  }

  func testPlayedInLastDaysMatchesRecentPlays() {
    makeSong(id: "s-played-2d", playCount: 3, lastPlayedDaysAgo: 2)
    makeSong(id: "s-played-40d", playCount: 3, lastPlayedDaysAgo: 40)
    makeSong(id: "s-never-played", playCount: 0)
    library.saveContext()

    XCTAssertEqual(matchedIds([.played(.inLastDays(30))]), ["s-played-2d"])
  }

  /// "Not played in the last N days" must include songs never played at all —
  /// they are the strongest match for the user's intent, and a nil date is not
  /// a reason to hide them.
  func testPlayedNotInLastDaysIncludesNeverPlayedSongs() {
    makeSong(id: "s-played-2d", playCount: 3, lastPlayedDaysAgo: 2)
    makeSong(id: "s-played-40d", playCount: 3, lastPlayedDaysAgo: 40)
    makeSong(id: "s-never-played", playCount: 0)
    library.saveContext()

    XCTAssertEqual(
      Set(matchedIds([.played(.notInLastDays(30))])),
      ["s-played-40d", "s-never-played"]
    )
  }

  // MARK: - Rule: playlistCount

  func testPlaylistCountFewerThanCountsOnlyRealUserPlaylists() {
    let unfiled = makeSong(id: "s-unfiled")
    let filedOnce = makeSong(id: "s-filed-1")
    let filedTwice = makeSong(id: "s-filed-2")
    makePlaylist(id: "pl-a", name: "Alpha").append(playable: filedOnce)
    makePlaylist(id: "pl-b", name: "Beta").append(playable: filedTwice)
    makePlaylist(id: "pl-c", name: "Gamma").append(playable: filedTwice)
    library.saveContext()
    XCTAssertNotNil(unfiled)

    XCTAssertEqual(
      Set(matchedIds([.playlistCount(comparison: .fewerThan, count: 2)])),
      ["s-unfiled", "s-filed-1"]
    )
  }

  func testPlaylistCountMoreThanMatchesHeavilyFiledSongs() {
    makeSong(id: "s-filed-1")
    let filedTwice = makeSong(id: "s-filed-2")
    makePlaylist(id: "pl-b", name: "Beta").append(playable: filedTwice)
    makePlaylist(id: "pl-c", name: "Gamma").append(playable: filedTwice)
    library.saveContext()

    XCTAssertEqual(matchedIds([.playlistCount(comparison: .moreThan, count: 1)]), ["s-filed-2"])
  }

  /// A song listed TWICE in ONE playlist sits in one playlist, not two. The
  /// original `SUBQUERY(playlistItems, …).@count` predicate counted entries, so
  /// this song was wrongly dropped from "fewer than 2 playlists" (BUG-2, QA
  /// 2026-08-17 — song 4bWTwsZlJfq8VOnt6mONHW, twice in `26_christmas_2010`).
  func testPlaylistCountFewerThanCountsDuplicateEntriesInOnePlaylistOnce() {
    let duplicatedTwice = makeSong(id: "s-dup-in-one")
    let filedInTwoPlaylists = makeSong(id: "s-in-two")
    let duplicateHostPlaylist = makePlaylist(id: "pl-dup", name: "Christmas 2010")
    duplicateHostPlaylist.append(playable: duplicatedTwice)
    duplicateHostPlaylist.append(playable: duplicatedTwice)
    makePlaylist(id: "pl-x", name: "X").append(playable: filedInTwoPlaylists)
    makePlaylist(id: "pl-y", name: "Y").append(playable: filedInTwoPlaylists)
    library.saveContext()

    XCTAssertEqual(
      matchedIds([.playlistCount(comparison: .fewerThan, count: 2)]),
      ["s-dup-in-one"]
    )
  }

  /// The same duplicate on the other side of the boundary: one playlist is not
  /// "more than 1 playlist", however many entries back it.
  func testPlaylistCountMoreThanCountsDuplicateEntriesInOnePlaylistOnce() {
    let duplicatedThrice = makeSong(id: "s-dup-in-one")
    let filedInTwoPlaylists = makeSong(id: "s-in-two")
    let duplicateHostPlaylist = makePlaylist(id: "pl-dup", name: "Christmas 2010")
    duplicateHostPlaylist.append(playable: duplicatedThrice)
    duplicateHostPlaylist.append(playable: duplicatedThrice)
    duplicateHostPlaylist.append(playable: duplicatedThrice)
    makePlaylist(id: "pl-x", name: "X").append(playable: filedInTwoPlaylists)
    makePlaylist(id: "pl-y", name: "Y").append(playable: filedInTwoPlaylists)
    library.saveContext()

    XCTAssertEqual(matchedIds([.playlistCount(comparison: .moreThan, count: 1)]), ["s-in-two"])
  }

  /// Duplicates must not distort the "we have no added-date for these" footer
  /// either — that count runs the same rules, so it takes the same distinct
  /// treatment.
  func testMissingAddedDateCountUsesDistinctPlaylistCounts() {
    let duplicatedTwice = makeSong(id: "s-dup-no-date")
    let filedInTwoPlaylists = makeSong(id: "s-two-no-date")
    let duplicateHostPlaylist = makePlaylist(id: "pl-dup", name: "Christmas 2010")
    duplicateHostPlaylist.append(playable: duplicatedTwice)
    duplicateHostPlaylist.append(playable: duplicatedTwice)
    makePlaylist(id: "pl-x", name: "X").append(playable: filedInTwoPlaylists)
    makePlaylist(id: "pl-y", name: "Y").append(playable: filedInTwoPlaylists)
    library.saveContext()

    let evaluation = evaluate([
      .addedWithinDays(7),
      .playlistCount(comparison: .fewerThan, count: 2),
    ])
    XCTAssertTrue(evaluation.songs.isEmpty)
    XCTAssertEqual(evaluation.songsMissingAddedDate, 1)
  }

  /// Smart playlists are derived rules, not curated membership, so they never
  /// contribute to a playlist count.
  func testPlaylistCountIgnoresSmartPlaylists() {
    let song = makeSong(id: "s-smart-only")
    let smartPlaylist = makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto",
      name: "Auto Mix"
    )
    smartPlaylist.append(playable: song)
    library.saveContext()

    XCTAssertEqual(matchedIds([.playlistCount(comparison: .fewerThan, count: 1)]), ["s-smart-only"])
  }

  /// Unnamed playlists model the Player's internal context/queue lists — they
  /// are not user filing either.
  func testPlaylistCountIgnoresUnnamedSystemPlaylists() {
    let song = makeSong(id: "s-system-only")
    makePlaylist(id: "pl-system", name: "").append(playable: song)
    library.saveContext()

    XCTAssertEqual(
      matchedIds([.playlistCount(comparison: .fewerThan, count: 1)]),
      ["s-system-only"]
    )
  }

  /// Membership is scoped through the PLAYLIST's account, so another account's
  /// playlist cannot influence this account's count.
  func testPlaylistCountIgnoresOtherAccountPlaylists() {
    let song = makeSong(id: "s-cross-account")
    let foreignPlaylist = makePlaylist(id: "pl-foreign", name: "Theirs", ownedBy: otherAccount)
    foreignPlaylist.append(playable: song)
    library.saveContext()

    XCTAssertEqual(
      matchedIds([.playlistCount(comparison: .fewerThan, count: 1)]),
      ["s-cross-account"]
    )
  }

  // MARK: - Rules: inPlaylist / notInPlaylist

  func testInPlaylistMatchesOnlyMembers() {
    let member = makeSong(id: "s-member")
    makeSong(id: "s-outsider")
    makePlaylist(id: "pl-target", name: "Target").append(playable: member)
    library.saveContext()

    XCTAssertEqual(
      matchedIds([.inPlaylist(playlistId: "pl-target", name: "Target")]),
      ["s-member"]
    )
  }

  func testNotInPlaylistMatchesOnlyNonMembers() {
    let member = makeSong(id: "s-member")
    makeSong(id: "s-outsider")
    makePlaylist(id: "pl-target", name: "Target").append(playable: member)
    library.saveContext()

    XCTAssertEqual(
      matchedIds([.notInPlaylist(playlistId: "pl-target", name: "Target")]),
      ["s-outsider"]
    )
  }

  /// Membership rules stay pure predicates because duplicates cannot skew a
  /// yes/no question: a song listed twice is in the playlist once, and the
  /// result must not contain it twice either.
  func testMembershipRulesAreUnaffectedByDuplicateEntries() {
    let duplicatedTwice = makeSong(id: "s-dup")
    makeSong(id: "s-outsider")
    let targetPlaylist = makePlaylist(id: "pl-target", name: "Target")
    targetPlaylist.append(playable: duplicatedTwice)
    targetPlaylist.append(playable: duplicatedTwice)
    library.saveContext()

    XCTAssertEqual(matchedIds([.inPlaylist(playlistId: "pl-target", name: "Target")]), ["s-dup"])
    XCTAssertEqual(
      matchedIds([.notInPlaylist(playlistId: "pl-target", name: "Target")]),
      ["s-outsider"]
    )
  }

  /// A rule pointing at a deleted playlist is DROPPED, not treated as
  /// "matches nothing" — otherwise the whole query would silently go empty and
  /// the user would have no idea why.
  func testVanishedPlaylistRuleIsDroppedAndReported() {
    makeSong(id: "s-a")
    makeSong(id: "s-b")
    library.saveContext()

    let evaluation = evaluate([.inPlaylist(playlistId: "pl-gone", name: "Deleted Mix")])
    XCTAssertEqual(Set(evaluation.songs.map { $0.id }), ["s-a", "s-b"])
    XCTAssertEqual(evaluation.droppedPlaylistRules.count, 1)
    XCTAssertEqual(evaluation.droppedPlaylistRules.first?.referencedPlaylistId, "pl-gone")
  }

  // MARK: - Combinations

  func testRulesAreAndCombined() {
    makeSong(id: "s-match", addedDaysAgo: 2, playCount: 0)
    makeSong(id: "s-too-old", addedDaysAgo: 40, playCount: 0)
    makeSong(id: "s-played", addedDaysAgo: 2, playCount: 5)
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(7), .played(.never)]), ["s-match"])
  }

  func testThreeRuleCombinationIncludingPlaylistMembership() {
    let unfiledFresh = makeSong(id: "s-keep", addedDaysAgo: 1, playCount: 0)
    let filedFresh = makeSong(id: "s-filed", addedDaysAgo: 1, playCount: 0)
    makeSong(id: "s-stale", addedDaysAgo: 90, playCount: 0)
    makePlaylist(id: "pl-done", name: "Done").append(playable: filedFresh)
    library.saveContext()
    XCTAssertNotNil(unfiledFresh)

    XCTAssertEqual(
      matchedIds([
        .addedWithinDays(30),
        .played(.never),
        .notInPlaylist(playlistId: "pl-done", name: "Done"),
      ]),
      ["s-keep"]
    )
  }

  /// An empty rule list is a valid query meaning "all songs" — the builder can
  /// present it before the user adds anything.
  func testEmptyQueryReturnsAllPlayableSongs() {
    makeSong(id: "s-a", addedDaysAgo: 1)
    makeSong(id: "s-b", addedDaysAgo: 2)
    library.saveContext()

    XCTAssertEqual(matchedIds([]), ["s-a", "s-b"])
  }

  // MARK: - Always-on guards

  /// The playable guard is not optional: a song deleted server-side with no
  /// local cache never appears, whatever the rules say.
  func testServerDeletedUncachedSongIsAlwaysExcluded() {
    makeSong(id: "s-visible", addedDaysAgo: 1)
    let ghost = makeSong(id: "s-ghost", addedDaysAgo: 1)
    ghost.remoteStatus = .deleted
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(30)]), ["s-visible"])
  }

  /// A cached song survives server-side deletion — the deliberate exception
  /// baked into `excludeServerDeleteUncachedSongsFetchPredicate`.
  func testServerDeletedButCachedSongIsStillIncluded() {
    let cachedGhost = makeSong(id: "s-cached-ghost", addedDaysAgo: 1)
    cachedGhost.remoteStatus = .deleted
    cachedGhost.relFilePath = URL(string: "cached/song.mp3")
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(30)]), ["s-cached-ghost"])
  }

  /// Results are scoped to the evaluating account.
  func testOtherAccountSongsAreExcluded() {
    makeSong(id: "s-mine", addedDaysAgo: 1)
    makeSong(id: "s-theirs", addedDaysAgo: 1, ownedBy: otherAccount)
    library.saveContext()

    XCTAssertEqual(matchedIds([.addedWithinDays(30)]), ["s-mine"])
  }

  // MARK: - Ordering

  /// `addedDate` DESC, unknown dates last, then title — the frozen order the
  /// store persists.
  func testResultsAreSortedByAddedDateDescendingWithUnknownDatesLast() {
    makeSong(id: "s-old", addedDaysAgo: 10)
    makeSong(id: "s-new", addedDaysAgo: 1)
    makeSong(id: "s-mid", addedDaysAgo: 5)
    makeSong(id: "s-unknown")
    library.saveContext()

    XCTAssertEqual(matchedIds([]), ["s-new", "s-mid", "s-old", "s-unknown"])
  }
}
