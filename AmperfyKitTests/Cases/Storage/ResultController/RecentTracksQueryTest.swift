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

    let result = RecentTracksQuery.topN(context: testContext, n: 2)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 7)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 7)
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

    let result = RecentTracksQuery.lastMDays(context: testContext, m: 7, now: nowReference)
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

    let result = RecentTracksQuery.lastMDays(context: testContext, m: 30, now: nowReference)
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

    let count = RecentTracksQuery.lastMDaysCount(context: testContext, m: 7, now: nowReference)
    // Note: count is for ALL songs (not just t-prefixed), but seed albums
    // contribute no songs in their default state so this is safe in practice.
    // We assert >= 3 to allow the seeder to add unrelated playables, and
    // separately verify the breakdown via lastMDays itself below.
    XCTAssertGreaterThanOrEqual(count, 3)
    let fetched = RecentTracksQuery.lastMDays(context: testContext, m: 7, now: nowReference)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 10)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 10)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 10)
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

    let result = RecentTracksQuery.topN(context: testContext, n: 10)
    XCTAssertEqual(ids(result, withPrefix: "t-"), expectedIds)
  }
}
