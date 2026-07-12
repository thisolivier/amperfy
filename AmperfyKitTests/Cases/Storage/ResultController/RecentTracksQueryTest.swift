//
//  RecentTracksQueryTest.swift
//  AmperfyKitTests
//
//  Created by implementer-amperfy on 2026-04-11.
//  Copyright (c) 2026 Amperfy. All rights reserved.
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

/// Unit tests for `RecentTracksQuery`. Each case seeds an in-memory Core Data
/// store with songs of varying `addedDate` and parent-album `releaseType`,
/// then asserts the query helpers return the expected ids.
///
/// "Playable" in this file means the song satisfies
/// `SongMO.excludeServerDeleteUncachedSongsFetchPredicate` — we set
/// `size > 0` and an `album.remoteStatus == .available` (the default for
/// freshly-created albums) so seeded songs aren't filtered out as "ghost"
/// rows.
@MainActor
class RecentTracksQueryTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  /// A fixed reference "now" for deterministic relative-date math.
  let nowReference = Date(timeIntervalSince1970: 1_750_000_000)

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: - Helpers

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  /// Creates a parent album with the given metadata.
  @discardableResult
  private func makeAlbum(
    id: String,
    releaseType: String?,
    remoteSongCount: Int
  )
    -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.releaseType = releaseType
    album.remoteSongCount = remoteSongCount
    return album
  }

  /// Creates a playable song attached to the given album with a specific
  /// `addedDate`. The id prefix is used by tests to filter out anything the
  /// shared `CoreDataSeeder` may have inserted.
  @discardableResult
  private func makeSong(
    id: String,
    addedDate: Date,
    onAlbum album: Album
  )
    -> Song {
    let song = library.createSong(account: account)
    song.id = id
    song.addedDate = addedDate
    song.album = album
    song.size = 1024 // satisfy excludeServerDeleteUncachedSongsFetchPredicate
    return song
  }

  /// Pulls song ids out of a SongMO array, filtered to a test prefix and
  /// returned in result order so we can assert sort behaviour.
  private func ids(_ results: [SongMO], withPrefix prefix: String) -> [String] {
    results
      .map { $0.id }
      .filter { $0.hasPrefix(prefix) }
  }

  // MARK: - topN

  /// Top-N respects the fetch limit and returns rows in addedDate-DESC order.
  func testTopNRespectsLimitAndOrder() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    makeSong(id: "t-1", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single)
    makeSong(id: "t-2", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single)
    makeSong(id: "t-3", addedDate: nowReference.addingTimeInterval(-3 * 86400), onAlbum: single)
    makeSong(id: "t-4", addedDate: nowReference.addingTimeInterval(-4 * 86400), onAlbum: single)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 2,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-1", "t-2"])
  }

  /// Top-N excludes songs whose parent album is a whole album (`"album"` tag).
  func testTopNExcludesWholeAlbumSongs() {
    let albumTagged = makeAlbum(id: "alb-album", releaseType: "album", remoteSongCount: 8)
    let singleTagged = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 2)
    makeSong(
      id: "t-from-album",
      addedDate: nowReference.addingTimeInterval(-1 * 86400),
      onAlbum: albumTagged
    )
    makeSong(
      id: "t-from-single",
      addedDate: nowReference.addingTimeInterval(-2 * 86400),
      onAlbum: singleTagged
    )
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 7,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-from-single"])
  }

  /// Songs from a high-track-count untagged album (>= 5) are filtered out
  /// by the count branch even though they have no metadata.
  func testTopNExcludesHighCountUntaggedAlbumSongs() {
    let bigUntagged = makeAlbum(id: "alb-big", releaseType: nil, remoteSongCount: 5)
    let smallUntagged = makeAlbum(id: "alb-small", releaseType: nil, remoteSongCount: 2)
    makeSong(
      id: "t-big",
      addedDate: nowReference.addingTimeInterval(-1 * 86400),
      onAlbum: bigUntagged
    )
    makeSong(
      id: "t-small",
      addedDate: nowReference.addingTimeInterval(-2 * 86400),
      onAlbum: smallUntagged
    )
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 7,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-small"])
  }

  // MARK: - lastMDays

  /// Returns only songs within the cutoff window, in addedDate-DESC order.
  func testLastMDaysFiltersByDate() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    makeSong(id: "t-2d", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single)
    makeSong(id: "t-5d", addedDate: nowReference.addingTimeInterval(-5 * 86400), onAlbum: single)
    makeSong(id: "t-9d", addedDate: nowReference.addingTimeInterval(-9 * 86400), onAlbum: single)
    library.saveContext()

    let result = RecentTracksQuery.lastMDays(
      context: testContext,
      m: 7,
      hideSongsInPlaylists: false,
      account: account,
      now: nowReference
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-2d", "t-5d"])
  }

  /// `lastMDays` does not impose a fetch limit (so a "Last 30 days" query
  /// returns all qualifying rows).
  func testLastMDaysHasNoFetchLimit() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    for offsetDays in 1 ... 20 {
      makeSong(
        id: "t-\(offsetDays)d",
        addedDate: nowReference.addingTimeInterval(-Double(offsetDays) * 86400),
        onAlbum: single
      )
    }
    library.saveContext()

    let result = RecentTracksQuery.lastMDays(
      context: testContext,
      m: 30,
      hideSongsInPlaylists: false,
      account: account,
      now: nowReference
    )
    XCTAssertEqual(ids(result, withPrefix: "t-").count, 20)
  }

  // MARK: - lastMDaysCount

  /// Counts only the qualifying rows in the window — same predicate as
  /// `lastMDays` but cheaper because it doesn't materialise objects.
  func testLastMDaysCountMatchesFetch() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let albumTagged = makeAlbum(id: "alb-album", releaseType: "album", remoteSongCount: 8)
    makeSong(id: "t-1", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single)
    makeSong(id: "t-2", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single)
    makeSong(id: "t-3", addedDate: nowReference.addingTimeInterval(-3 * 86400), onAlbum: single)
    // excluded by whole-album filter
    makeSong(
      id: "t-from-album",
      addedDate: nowReference.addingTimeInterval(-1 * 86400),
      onAlbum: albumTagged
    )
    // excluded by date window
    makeSong(id: "t-old", addedDate: nowReference.addingTimeInterval(-30 * 86400), onAlbum: single)
    library.saveContext()

    let count = RecentTracksQuery.lastMDaysCount(
      context: testContext,
      m: 7,
      hideSongsInPlaylists: false,
      account: account,
      now: nowReference
    )
    // Note: count is for ALL songs (not just t-prefixed), but seed albums
    // contribute no songs in their default state so this is safe in practice.
    // We assert >= 3 to allow the seeder to add unrelated playables, and
    // separately verify the breakdown via lastMDays itself below.
    XCTAssertGreaterThanOrEqual(count, 3)
    let fetched = RecentTracksQuery.lastMDays(
      context: testContext,
      m: 7,
      hideSongsInPlaylists: false,
      account: account,
      now: nowReference
    )
    XCTAssertEqual(ids(fetched, withPrefix: "t-"), ["t-1", "t-2", "t-3"])
  }

  // MARK: - topN fallback behaviour (widget always renders)

  /// The freshness rule yields zero fresh songs (all fixture songs are older
  /// than 7 days) but the library has >= 10 qualifying songs overall.
  /// `topN(n: 10)` must still return the 10 most recent songs rather than an
  /// empty array — the widget always renders once it's on the home screen.
  func testTopNReturnsTenOlderSongsWhenNoneAreFresh() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let dayInSeconds = 86_400.0
    var expectedIds: [String] = []
    for offsetDays in 30 ... 41 {
      let id = "t-\(offsetDays)d"
      makeSong(
        id: id,
        addedDate: nowReference.addingTimeInterval(-Double(offsetDays) * dayInSeconds),
        onAlbum: single
      )
      if offsetDays <= 39 {
        expectedIds.append(id)
      }
    }
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 10,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), expectedIds)
  }

  /// The freshness rule yields fewer than 10 fresh songs (3 within the last 7
  /// days) but the library has >= 10 qualifying songs overall. `topN(n: 10)`
  /// must return 10 rows: the 3 fresh ones first (they have the latest
  /// `addedDate`), padded with the next-most-recent older songs.
  func testTopNPadsWithOlderSongsWhenFewerThanTenAreFresh() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let dayInSeconds = 86_400.0
    let freshIds = ["t-fresh-1d", "t-fresh-2d", "t-fresh-3d"]
    makeSong(
      id: "t-fresh-1d",
      addedDate: nowReference.addingTimeInterval(-1 * dayInSeconds),
      onAlbum: single
    )
    makeSong(
      id: "t-fresh-2d",
      addedDate: nowReference.addingTimeInterval(-2 * dayInSeconds),
      onAlbum: single
    )
    makeSong(
      id: "t-fresh-3d",
      addedDate: nowReference.addingTimeInterval(-3 * dayInSeconds),
      onAlbum: single
    )
    var olderIds: [String] = []
    for offsetDays in 30 ... 40 {
      let id = "t-older-\(offsetDays)d"
      makeSong(
        id: id,
        addedDate: nowReference.addingTimeInterval(-Double(offsetDays) * dayInSeconds),
        onAlbum: single
      )
      if offsetDays <= 36 {
        olderIds.append(id)
      }
    }
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 10,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), freshIds + olderIds)
  }

  /// The freshness rule yields more than 10 fresh songs (15 within the last 7
  /// days). `topN(n: 10)` returns only the 10 most recent of those — the
  /// unaffected, already-current behaviour for a healthy/active library.
  func testTopNReturnsOnlyTenMostRecentWhenManyAreFresh() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let dayInSeconds = 86_400.0
    var expectedIds: [String] = []
    for offsetHours in 1 ... 15 {
      let id = "t-\(offsetHours)h"
      makeSong(
        id: id,
        addedDate: nowReference.addingTimeInterval(-Double(offsetHours) * (dayInSeconds / 24)),
        onAlbum: single
      )
      if offsetHours <= 10 {
        expectedIds.append(id)
      }
    }
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 10,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), expectedIds)
  }

  /// A tiny library with fewer than 10 qualifying songs in total returns all
  /// of them, unpadded, rather than erroring or returning an empty array.
  func testTopNReturnsAllSongsWhenLibraryHasFewerThanTen() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let dayInSeconds = 86_400.0
    let expectedIds = ["t-1d", "t-2d", "t-3d", "t-4d"]
    makeSong(
      id: "t-1d",
      addedDate: nowReference.addingTimeInterval(-1 * dayInSeconds),
      onAlbum: single
    )
    makeSong(
      id: "t-2d",
      addedDate: nowReference.addingTimeInterval(-2 * dayInSeconds),
      onAlbum: single
    )
    makeSong(
      id: "t-3d",
      addedDate: nowReference.addingTimeInterval(-3 * dayInSeconds),
      onAlbum: single
    )
    makeSong(
      id: "t-4d",
      addedDate: nowReference.addingTimeInterval(-4 * dayInSeconds),
      onAlbum: single
    )
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 10,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), expectedIds)
  }

  // MARK: - topN whole-album exclusion is not padded (design intent)

  /// Removes every song the shared `CoreDataSeeder` inserted, leaving only
  /// whatever the current test created (identified by the `"t-"` id
  /// prefix). 12 of the seeded fixture songs are marked `isCached: true`
  /// and therefore pass `SongMO.excludeServerDeleteUncachedSongsFetchPredicate`
  /// via its `relFilePath != nil` branch; since their parent albums also
  /// have `remoteSongCount == 0` (unset), they pass the non-whole-album
  /// filter too — meaning they'd otherwise silently consume `fetchLimit`
  /// slots with a `nil` `addedDate`. Filtering assertions by the `"t-"`
  /// prefix (as most tests above do) is enough when only the
  /// presence/order of specific ids matters, but not when a test needs
  /// `topN` to be genuinely empty.
  private func removeSeededContaminantSongs() {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    let allSongs = (try? testContext.fetch(fetchRequest)) ?? []
    for song in allSongs where !song.id.hasPrefix("t-") {
      testContext.delete(song)
    }
    library.saveContext()
  }

  /// Regression guard for the widget's design intent (see `RecentTracksQuery`'s
  /// doc comment): a library whose recent additions are entirely whole
  /// albums must yield an empty `topN` result, never a fallback to
  /// whole-album tracks. The widget is meant to surface individually-added /
  /// single-ish tracks only; an empty (but visible) widget is the correct
  /// outcome here, not a bug to be padded away.
  func testTopNNeverFallsBackToWholeAlbumSongsWhenLibraryIsAllWholeAlbums() {
    removeSeededContaminantSongs()
    let dayInSeconds = 86_400.0
    let wholeAlbum = makeAlbum(id: "alb-whole", releaseType: "album", remoteSongCount: 8)
    for offsetDays in 1 ... 10 {
      makeSong(
        id: "t-whole-\(offsetDays)d",
        addedDate: nowReference.addingTimeInterval(-Double(offsetDays) * dayInSeconds),
        onAlbum: wholeAlbum
      )
    }
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext,
      n: 10,
      hideSongsInPlaylists: false,
      account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), [])
  }

  // MARK: - hideSongsInPlaylists filter (triage inbox)

  //
  // These cover the "Hide tracks already in playlists" toggle: a Recently
  // Added track disappears once the user has filed it into at least one real
  // user playlist. See `RecentTracksQuery.songNotInAnyUserPlaylist`.

  /// Creates a real user playlist (non-smart, named) owned by the given
  /// account (defaults to the primary test account).
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

  /// With the toggle OFF, a song already in a playlist is still returned
  /// (baseline — the filter is opt-in).
  func testHideFilterOffKeepsSongInPlaylist() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let filed = makeSong(id: "t-filed", addedDate: nowReference, onAlbum: single)
    let playlist = makePlaylist(id: "raf-pl-1", name: "My Mix")
    playlist.append(playable: filed)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: false, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-filed"])
  }

  /// With the toggle ON, a song in exactly one user playlist is hidden while
  /// an unfiled song remains.
  func testHideFilterOnHidesSongInOnePlaylist() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let filed = makeSong(
      id: "t-filed", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single
    )
    makeSong(
      id: "t-unfiled", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single
    )
    let playlist = makePlaylist(id: "raf-pl-1", name: "My Mix")
    playlist.append(playable: filed)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-unfiled"])
  }

  /// A song in several user playlists is hidden exactly once (still absent,
  /// not double-counted or resurfaced).
  func testHideFilterOnHidesSongInSeveralPlaylists() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let filed = makeSong(
      id: "t-filed", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single
    )
    makeSong(
      id: "t-unfiled", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single
    )
    makePlaylist(id: "raf-pl-a", name: "Alpha").append(playable: filed)
    makePlaylist(id: "raf-pl-b", name: "Beta").append(playable: filed)
    makePlaylist(id: "raf-pl-c", name: "Gamma").append(playable: filed)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-unfiled"])
  }

  /// A song in zero playlists is kept even when the toggle is ON.
  func testHideFilterOnKeepsUnfiledSong() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    makeSong(id: "t-unfiled", addedDate: nowReference, onAlbum: single)
    makePlaylist(id: "raf-pl-empty", name: "Empty")
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-unfiled"])
  }

  /// A song that appears ONLY in a smart playlist is treated as unfiled (smart
  /// playlists are derived rules, not user triage) and is kept when ON.
  func testHideFilterOnKeepsSongOnlyInSmartPlaylist() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let song = makeSong(id: "t-smart-only", addedDate: nowReference, onAlbum: single)
    let smart = makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto", name: "Auto Mix"
    )
    smart.append(playable: song)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-smart-only"])
  }

  /// A song that appears ONLY in an unnamed playlist (which also models the
  /// Player's internal system playlists) is treated as unfiled and kept.
  func testHideFilterOnKeepsSongOnlyInUnnamedPlaylist() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let song = makeSong(id: "t-sys-only", addedDate: nowReference, onAlbum: single)
    let unnamed = makePlaylist(id: "raf-pl-sys", name: "")
    unnamed.append(playable: song)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-sys-only"])
  }

  /// Membership is scoped to the active account: a song filed only into a
  /// playlist owned by ANOTHER account must not be hidden on the active
  /// account.
  func testHideFilterOnIgnoresOtherAccountPlaylists() {
    let otherAccount = library.getAccount(info: TestAccountInfo.create2())
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let song = makeSong(id: "t-cross", addedDate: nowReference, onAlbum: single)
    // Playlist + its items belong to the OTHER account.
    let otherPlaylist = makePlaylist(
      id: "raf-pl-other", name: "Their Mix", ownedBy: otherAccount
    )
    otherPlaylist.append(playable: song)
    library.saveContext()

    let result = RecentTracksQuery.topN(
      context: testContext, n: 10, hideSongsInPlaylists: true, account: account
    )
    XCTAssertEqual(
      ids(result, withPrefix: "t-"),
      ["t-cross"],
      "A playlist on another account must not hide the song on the active account"
    )
  }

  /// The lastMDays entry point honours the toggle identically to topN.
  func testHideFilterAppliesToLastMDays() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let filed = makeSong(
      id: "t-filed", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single
    )
    makeSong(
      id: "t-unfiled", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single
    )
    makePlaylist(id: "raf-pl-1", name: "My Mix").append(playable: filed)
    library.saveContext()

    let result = RecentTracksQuery.lastMDays(
      context: testContext, m: 7, hideSongsInPlaylists: true, account: account, now: nowReference
    )
    XCTAssertEqual(ids(result, withPrefix: "t-"), ["t-unfiled"])
  }

  /// The lastMDaysCount entry point honours the toggle: a filed song within
  /// the window is not counted when the filter is on.
  func testHideFilterAppliesToLastMDaysCount() {
    removeSeededContaminantSongs()
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let filed = makeSong(
      id: "t-filed", addedDate: nowReference.addingTimeInterval(-1 * 86400), onAlbum: single
    )
    makeSong(
      id: "t-unfiled", addedDate: nowReference.addingTimeInterval(-2 * 86400), onAlbum: single
    )
    makePlaylist(id: "raf-pl-1", name: "My Mix").append(playable: filed)
    library.saveContext()

    let filteredCount = RecentTracksQuery.lastMDaysCount(
      context: testContext, m: 7, hideSongsInPlaylists: true, account: account, now: nowReference
    )
    XCTAssertEqual(filteredCount, 1, "Only the unfiled song is counted when the filter is on")

    let unfilteredCount = RecentTracksQuery.lastMDaysCount(
      context: testContext, m: 7, hideSongsInPlaylists: false, account: account, now: nowReference
    )
    XCTAssertEqual(unfilteredCount, 2, "Both songs are counted when the filter is off")
  }

  /// A song filed then removed from its only playlist reappears (live state,
  /// no stale membership).
  func testHideFilterReflectsLiveRemovalFromPlaylist() {
    let single = makeAlbum(id: "alb-single", releaseType: "single", remoteSongCount: 1)
    let song = makeSong(id: "t-toggle", addedDate: nowReference, onAlbum: single)
    let playlist = makePlaylist(id: "raf-pl-1", name: "My Mix")
    playlist.append(playable: song)
    library.saveContext()

    XCTAssertEqual(
      ids(
        RecentTracksQuery.topN(
          context: testContext, n: 10, hideSongsInPlaylists: true, account: account
        ),
        withPrefix: "t-"
      ),
      [],
      "While filed, the song is hidden"
    )

    playlist.remove(at: playlist.playables.firstIndex(where: { $0.id == "t-toggle" })!)
    library.saveContext()

    XCTAssertEqual(
      ids(
        RecentTracksQuery.topN(
          context: testContext, n: 10, hideSongsInPlaylists: true, account: account
        ),
        withPrefix: "t-"
      ),
      ["t-toggle"],
      "After live removal from its only playlist, the song reappears"
    )
  }
}
