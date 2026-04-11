//
//  WholeAlbumPredicatesTest.swift
//  AmperfyKitTests
//
//  Created by implementer-amperfy on 2026-04-10.
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

/// Unit tests for `WholeAlbumPredicates`. Each case seeds a fresh in-memory
/// Core Data stack, creates one or more `Album` entities with different
/// combinations of `releaseType` and `remoteSongCount`, and then runs a
/// fetch with the predicate under test, asserting which albums come back.
///
/// See `spike/amperfy/BACKLOG.md` §1.5 for the authoritative case list.
@MainActor
class WholeAlbumPredicatesTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: - Helpers

  /// Creates a fresh album with the given metadata and persists it.
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

  /// The managed object context the seeded library uses. `CoreDataHelper`
  /// creates a single in-memory container whose `viewContext` is what
  /// `LibraryStorage` wraps, so we read directly from the same context rather
  /// than plumbing a dedicated accessor through the production API.
  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  /// Fetches albums matching the predicate and returns the ids that the
  /// current test case seeded (filtered by the given prefix). Filtering by
  /// prefix keeps the assertions clean regardless of what the shared
  /// `CoreDataSeeder` adds to the in-memory store.
  private func fetchAlbumIds(
    matching predicate: NSPredicate,
    withPrefix prefix: String
  )
    -> [String] {
    let fetchRequest: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
    fetchRequest.predicate = predicate
    let managedObjects = try! testContext.fetch(fetchRequest)
    return managedObjects
      .map { $0.id }
      .filter { $0.hasPrefix(prefix) }
      .sorted()
  }

  // MARK: - wholeAlbum(minSongCount:) — metadata wins over count

  /// Metadata-tagged `"single"` must NOT match even when `remoteSongCount`
  /// exceeds the threshold. This is the core "metadata wins over count" rule.
  func testSingleWithManyTracksIsNotWhole() {
    makeAlbum(id: "a-single-5-tracks", releaseType: "single", remoteSongCount: 5)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      [],
      "An album explicitly tagged as 'single' must never be a whole album, even with 5 tracks"
    )
  }

  /// Metadata-tagged `"album"` with zero tracks must match — the tag is
  /// authoritative and the count fallback does not need to engage.
  func testAlbumTagWithZeroTracksIsWhole() {
    makeAlbum(id: "a-album-0-tracks", releaseType: "album", remoteSongCount: 0)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-album-0-tracks"])
  }

  /// Metadata-tagged `"ep"` must match.
  func testEpTagIsWhole() {
    makeAlbum(id: "a-ep-2-tracks", releaseType: "ep", remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-ep-2-tracks"])
  }

  /// Case-insensitive match: parser stores lowercased, but we assert the
  /// predicate tolerates mixed case just in case something slips through.
  func testAlbumTagCaseInsensitive() {
    makeAlbum(id: "a-album-mixed-case", releaseType: "Album", remoteSongCount: 1)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-album-mixed-case"])
  }

  /// Multi-value metadata like `"album, compilation"` must match because
  /// `CONTAINS[c] "album"` is true regardless of whether other tokens follow.
  /// This is the compilation case — compilations ARE albums for our purposes.
  func testCompilationMultiValueIsWhole() {
    makeAlbum(id: "a-compilation", releaseType: "album, compilation", remoteSongCount: 12)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-compilation"])
  }

  /// A metadata-tagged `"compilation"` ALONE (without `album`) does NOT
  /// contain the `"album"` or `"ep"` substring, and if its `remoteSongCount`
  /// is below the threshold it will not match. This documents the edge.
  func testCompilationOnlyBelowThresholdIsNotWhole() {
    makeAlbum(id: "a-comp-only-2", releaseType: "compilation", remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      [],
      "A bare 'compilation' tag without 'album' and below threshold should not match"
    )
  }

  /// A metadata-tagged `"compilation"` ALONE but with `remoteSongCount` at or
  /// above the threshold matches via the count fallback branch.
  func testCompilationOnlyAtThresholdIsWholeViaCount() {
    makeAlbum(id: "a-comp-only-3", releaseType: "compilation", remoteSongCount: 3)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      ["a-comp-only-3"],
      "A 'compilation' tag with >= minSongCount tracks matches via the count branch"
    )
  }

  // MARK: - wholeAlbum(minSongCount:) — count fallback when metadata is nil

  /// Nil metadata with `remoteSongCount` at the threshold must match.
  func testNilMetadataAtThresholdIsWhole() {
    makeAlbum(id: "a-nil-3", releaseType: nil, remoteSongCount: 3)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-nil-3"])
  }

  /// Nil metadata with `remoteSongCount` below threshold must NOT match.
  func testNilMetadataBelowThresholdIsNotWhole() {
    makeAlbum(id: "a-nil-2", releaseType: nil, remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, [])
  }

  // MARK: - Mixed-library smoke test

  /// Seeds a library with every case in one go and asserts the filtered
  /// result set is exactly the expected whole albums. This catches any case
  /// where the predicate accidentally matches everything or nothing.
  func testMixedLibraryFilter() {
    makeAlbum(id: "m-single-5", releaseType: "single", remoteSongCount: 5) // no
    makeAlbum(id: "m-album-0", releaseType: "album", remoteSongCount: 0) // yes
    makeAlbum(id: "m-ep-4", releaseType: "ep", remoteSongCount: 4) // yes
    makeAlbum(id: "m-nil-3", releaseType: nil, remoteSongCount: 3) // yes
    makeAlbum(id: "m-nil-1", releaseType: nil, remoteSongCount: 1) // no
    makeAlbum(id: "m-album-comp", releaseType: "album, compilation", remoteSongCount: 12) // yes
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "m-"
    )
    XCTAssertEqual(matched, ["m-album-0", "m-album-comp", "m-ep-4", "m-nil-3"])
  }

  // MARK: - songFromNonWholeAlbum(minSongCount:)

  /// Songs attached to a "single"-tagged album (regardless of track count) are
  /// matched as coming from a non-whole album.
  func testSongFromSingleTaggedAlbumMatches() {
    let album = makeAlbum(id: "s-single", releaseType: "single", remoteSongCount: 5)
    let song = library.createSong(account: account)
    song.id = "song-from-single"
    song.album = album
    library.saveContext()

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 3)
    let matched = try! testContext.fetch(fetchRequest)
      .map { $0.id }
      .filter { $0 == "song-from-single" }
    XCTAssertEqual(matched, ["song-from-single"])
  }

  /// Songs attached to an "album"-tagged parent are NOT matched by the
  /// non-whole-album predicate.
  func testSongFromAlbumTaggedAlbumDoesNotMatch() {
    let album = makeAlbum(id: "s-album", releaseType: "album", remoteSongCount: 10)
    let song = library.createSong(account: account)
    song.id = "song-from-album-only"
    song.album = album
    library.saveContext()

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 3)
    let matched = try! testContext.fetch(fetchRequest)
      .map { $0.id }
      .filter { $0 == "song-from-album-only" }
    XCTAssertEqual(matched, [])
  }
}
