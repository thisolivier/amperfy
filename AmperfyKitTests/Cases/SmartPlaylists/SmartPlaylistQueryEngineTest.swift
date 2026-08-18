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

  /// A song hung off a specific album — `nil` means "no album at all", which
  /// also needs a cached file path to survive
  /// `excludeServerDeleteUncachedSongsFetchPredicate` (that guard reads the
  /// ALBUM's remote status, so an album-less song is only visible when cached).
  @discardableResult
  private func makeSong(id: String, inAlbum album: Album?) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    song.title = id
    song.size = 1024
    song.album = album
    if album == nil {
      song.relFilePath = URL(string: "cached/\(id).mp3")
    }
    return song
  }

  @discardableResult
  private func makeAlbum(id: String, releaseType: String?, remoteSongCount: Int) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.releaseType = releaseType
    album.remoteSongCount = remoteSongCount
    return album
  }

  private func evaluate(_ rules: [SmartPlaylistRule]) -> SmartPlaylistEvaluation {
    evaluate(SmartPlaylistQuery(rules: rules))
  }

  private func matchedIds(_ rules: [SmartPlaylistRule]) -> [String] {
    evaluate(rules).songs.map { $0.id }
  }

  private func evaluate(_ query: SmartPlaylistQuery) -> SmartPlaylistEvaluation {
    SmartPlaylistQueryEngine.evaluate(
      query: query,
      context: testContext,
      account: account,
      now: nowReference
    )
  }

  private func matchedIds(_ query: SmartPlaylistQuery) -> [String] {
    evaluate(query).songs.map { $0.id }
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

  // MARK: - Rule: completeAlbum

  /// The truth table of `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)`,
  /// re-asserted through the Swift mirror the engine uses. `"single"` vetoes
  /// however many tracks the release carries.
  func testCompleteAlbumSingleTaggedWithManyTracksIsNotComplete() {
    let singleWithManyTracks = makeAlbum(
      id: "al-single",
      releaseType: "single",
      remoteSongCount: 10
    )
    makeSong(id: "s-single", inAlbum: singleWithManyTracks)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), [])
    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: false)]), ["s-single"])
  }

  /// Nil metadata is classified purely by count — `getAlbumList2` usually omits
  /// `releaseTypes`, so "no metadata" must never mean "excluded".
  func testCompleteAlbumUntaggedSingleTrackIsNotComplete() {
    let untaggedOneTrack = makeAlbum(id: "al-nil-1", releaseType: nil, remoteSongCount: 1)
    makeSong(id: "s-nil-1", inAlbum: untaggedOneTrack)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), [])
    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: false)]), ["s-nil-1"])
  }

  func testCompleteAlbumUntaggedThreeTrackIsComplete() {
    let untaggedThreeTracks = makeAlbum(id: "al-nil-3", releaseType: nil, remoteSongCount: 3)
    makeSong(id: "s-nil-3", inAlbum: untaggedThreeTracks)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), ["s-nil-3"])
    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: false)]), [])
  }

  /// A song with no album at all is NOT part of a complete album — the one
  /// place the Swift mirror must state what the Core Data predicate could only
  /// imply through NULL propagation.
  func testCompleteAlbumSongWithoutAlbumIsNotComplete() {
    makeSong(id: "s-orphan", inAlbum: nil)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), [])
    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: false)]), ["s-orphan"])
  }

  /// A metadata value that merely CONTAINS "single" still vetoes, matching the
  /// predicate's `CONTAINS[c]` semantics, and the check is case-insensitive.
  func testCompleteAlbumReleaseTypeContainingSingleVetoesCaseInsensitively() {
    let compilationOfSingles = makeAlbum(
      id: "al-mixed",
      releaseType: "Album, Single",
      remoteSongCount: 12
    )
    makeSong(id: "s-mixed", inAlbum: compilationOfSingles)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), [])
  }

  /// A non-"single" tag is ignored for positive matching: the count decides.
  func testCompleteAlbumCompilationIsCompleteViaCount() {
    let compilation = makeAlbum(id: "al-comp", releaseType: "compilation", remoteSongCount: 6)
    makeSong(id: "s-comp", inAlbum: compilation)
    library.saveContext()

    XCTAssertEqual(matchedIds([.completeAlbum(isComplete: true)]), ["s-comp"])
  }

  // MARK: - Boolean trees

  /// An `.any` top level is a plain OR across its items.
  func testTopLevelAnyCombinatorUnionsItsRules() {
    makeSong(id: "s-fresh", addedDaysAgo: 1, playCount: 9)
    makeSong(id: "s-unplayed", addedDaysAgo: 90, playCount: 0)
    makeSong(id: "s-neither", addedDaysAgo: 90, playCount: 9)
    library.saveContext()

    let query = SmartPlaylistQuery(
      combinator: .any,
      items: [.rule(.addedWithinDays(7)), .rule(.played(.never))]
    )
    XCTAssertEqual(Set(matchedIds(query)), ["s-fresh", "s-unplayed"])
  }

  /// The shape the addendum's summary example describes:
  /// `A and (B or C)` — an AND top level holding one OR group.
  func testAndTopLevelWithOrGroup() {
    let freshUnplayed = makeSong(id: "s-fresh-unplayed", addedDaysAgo: 1, playCount: 0)
    let freshFiled = makeSong(id: "s-fresh-filed", addedDaysAgo: 1, playCount: 9)
    makeSong(id: "s-fresh-neither", addedDaysAgo: 1, playCount: 9)
    makeSong(id: "s-stale-unplayed", addedDaysAgo: 90, playCount: 0)
    makePlaylist(id: "pl-target", name: "Target").append(playable: freshFiled)
    library.saveContext()
    XCTAssertNotNil(freshUnplayed)

    let query = SmartPlaylistQuery(items: [
      .rule(.addedWithinDays(7)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .played(.never),
        .inPlaylist(playlistId: "pl-target", name: "Target"),
      ])),
    ])
    XCTAssertEqual(Set(matchedIds(query)), ["s-fresh-unplayed", "s-fresh-filed"])
  }

  /// A group of one rule is legal and behaves exactly like the bare rule —
  /// the builder creates one the moment the user taps "+ Add group".
  func testGroupOfOneBehavesLikeABareRule() {
    makeSong(id: "s-never", playCount: 0)
    makeSong(id: "s-played", playCount: 3)
    library.saveContext()

    let groupedQuery = SmartPlaylistQuery(items: [
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [.played(.never)])),
    ])
    XCTAssertEqual(matchedIds(groupedQuery), ["s-never"])
    XCTAssertEqual(matchedIds(groupedQuery), matchedIds([.played(.never)]))
  }

  /// An empty top level means "all songs", whatever the combinator says — an
  /// `.any` container with nothing in it must not evaluate to "nothing".
  func testEmptyTopLevelMatchesEverythingUnderBothCombinators() {
    makeSong(id: "s-a", addedDaysAgo: 1)
    makeSong(id: "s-b", addedDaysAgo: 2)
    library.saveContext()

    XCTAssertEqual(matchedIds(SmartPlaylistQuery(combinator: .all, items: [])), ["s-a", "s-b"])
    XCTAssertEqual(matchedIds(SmartPlaylistQuery(combinator: .any, items: [])), ["s-a", "s-b"])
  }

  /// The three rule kinds that are answered from precomputed maps rather than
  /// from the song's own columns, all ORed together in one group.
  func testOrAcrossMembershipPlaylistCountAndCompleteAlbum() {
    let completeAlbum = makeAlbum(id: "al-whole", releaseType: nil, remoteSongCount: 8)
    let member = makeSong(id: "s-member", inAlbum: hostAlbum)
    let heavilyFiled = makeSong(id: "s-filed", inAlbum: hostAlbum)
    makeSong(id: "s-complete", inAlbum: completeAlbum)
    makeSong(id: "s-none", inAlbum: hostAlbum)
    makePlaylist(id: "pl-target", name: "Target").append(playable: member)
    makePlaylist(id: "pl-x", name: "X").append(playable: heavilyFiled)
    makePlaylist(id: "pl-y", name: "Y").append(playable: heavilyFiled)
    library.saveContext()

    let query = SmartPlaylistQuery(
      combinator: .any,
      items: [
        .rule(.inPlaylist(playlistId: "pl-target", name: "Target")),
        .rule(.playlistCount(comparison: .moreThan, count: 1)),
        .rule(.completeAlbum(isComplete: true)),
      ]
    )
    XCTAssertEqual(Set(matchedIds(query)), ["s-member", "s-filed", "s-complete"])
  }

  /// Nesting is one level deep, so `(A or B) and (C or D)` is the widest shape
  /// the model expresses — and it must actually intersect the two groups.
  func testTwoOrGroupsAreIntersectedByTheAndTopLevel() {
    makeSong(id: "s-both", addedDaysAgo: 1, playCount: 0)
    makeSong(id: "s-first-only", addedDaysAgo: 1, playCount: 5, lastPlayedDaysAgo: 1)
    makeSong(id: "s-second-only", addedDaysAgo: 200, playCount: 0)
    library.saveContext()

    let query = SmartPlaylistQuery(items: [
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .addedWithinDays(7),
        .addedWithinDays(14),
      ])),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .played(.never),
        .played(.notInLastDays(30)),
      ])),
    ])
    XCTAssertEqual(matchedIds(query), ["s-both"])
  }

  /// A vanished playlist inside an OR group must LOOSEN the query: the rule is
  /// dropped and, if that empties the group, the group goes too — an empty OR
  /// group would otherwise blank the entire result.
  func testVanishedPlaylistRuleInsideGroupIsDroppedWithoutEmptyingTheQuery() {
    makeSong(id: "s-a", addedDaysAgo: 1)
    makeSong(id: "s-b", addedDaysAgo: 2)
    library.saveContext()

    let query = SmartPlaylistQuery(items: [
      .rule(.addedWithinDays(30)),
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .inPlaylist(playlistId: "pl-gone", name: "Deleted Mix"),
      ])),
    ])
    let evaluation = evaluate(query)
    XCTAssertEqual(Set(evaluation.songs.map { $0.id }), ["s-a", "s-b"])
    XCTAssertEqual(evaluation.droppedPlaylistRules.count, 1)
    XCTAssertEqual(evaluation.droppedPlaylistRules.first?.referencedPlaylistId, "pl-gone")
  }

  // MARK: - Tree-aware missing-added-date count

  /// The count is "would match if every added-within rule were satisfied, but
  /// does not match as things stand". A nil-date song that already qualifies
  /// through an OR branch IS in the results, so it is NOT part of the count —
  /// nothing is being hidden from the user in its case.
  func testMissingAddedDateCountExcludesSongsQualifyingViaAnOrBranch() {
    makeSong(id: "s-nil-unplayed", playCount: 0)
    makeSong(id: "s-nil-played", playCount: 7)
    library.saveContext()

    let query = SmartPlaylistQuery(
      combinator: .any,
      items: [.rule(.addedWithinDays(7)), .rule(.played(.never))]
    )
    let evaluation = evaluate(query)
    XCTAssertEqual(evaluation.songs.map { $0.id }, ["s-nil-unplayed"])
    // Only the played song is kept out purely by the unknown added-date.
    XCTAssertEqual(evaluation.songsMissingAddedDate, 1)
  }

  /// Inside a group the same rule holds: the count respects the whole tree, not
  /// just the top level.
  func testMissingAddedDateCountHonoursRulesInsideGroups() {
    makeSong(id: "s-nil-unplayed", playCount: 0)
    makeSong(id: "s-nil-played", playCount: 7)
    library.saveContext()

    let query = SmartPlaylistQuery(items: [
      .group(SmartPlaylistRuleGroup(combinator: .all, rules: [
        .addedWithinDays(7),
        .played(.never),
      ])),
    ])
    let evaluation = evaluate(query)
    XCTAssertTrue(evaluation.songs.isEmpty)
    XCTAssertEqual(evaluation.songsMissingAddedDate, 1)
  }

  /// A song with a KNOWN added-date that simply falls outside the window is not
  /// "missing a date" — it is a plain non-match.
  func testMissingAddedDateCountIgnoresSongsWithKnownDates() {
    makeSong(id: "s-old", addedDaysAgo: 400, playCount: 0)
    library.saveContext()

    XCTAssertEqual(evaluate([.addedWithinDays(7)]).songsMissingAddedDate, 0)
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
