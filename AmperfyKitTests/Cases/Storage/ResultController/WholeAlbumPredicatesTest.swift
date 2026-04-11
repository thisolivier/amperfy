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
/// The rule under test (Option C — pure count + `"single"` veto):
/// an album is whole iff it is not tagged `"single"` AND
/// `remoteSongCount >= minSongCount`. See
/// `AmperfyKit/Storage/ResultController/WholeAlbumPredicates.swift` for the
/// rationale, and `spike/amperfy/BACKLOG.md` §1.1 / §4 for the decision log.
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

  /// The managed object context the seeded library uses.
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

  // MARK: - wholeAlbum(minSongCount:) — "single" veto

  /// Metadata-tagged `"single"` must NOT match even when `remoteSongCount`
  /// meets the threshold. The `"single"` tag is the sole metadata veto.
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

  // MARK: - wholeAlbum(minSongCount:) — metadata is NOT a positive signal

  /// An `"album"`-tagged release with only 1 track is NOT whole: the
  /// count floor is authoritative. Under the old metadata-positive rule
  /// this would have matched; the rewrite deliberately drops that branch
  /// because real-world libraries have too many mis-tagged single-track
  /// "albums".
  func testAlbumTagWithOneTrackIsNotWhole() {
    makeAlbum(id: "a-album-1-track", releaseType: "album", remoteSongCount: 1)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      [],
      "The 'album' metadata tag no longer forces a positive match — the count floor must still be satisfied"
    )
  }

  /// An `"ep"`-tagged release with 2 tracks at threshold 3 is NOT whole.
  /// Legitimate 2-track EPs are an intentionally unsupported edge case in
  /// the pure-count rule; see the decision log in `BACKLOG.md` §4.
  func testEpTagBelowThresholdIsNotWhole() {
    makeAlbum(id: "a-ep-2-tracks", releaseType: "ep", remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      [],
      "A 2-track EP no longer slips through via metadata — intentional pure-count regression"
    )
  }

  /// An `"album"`-tagged release with `remoteSongCount` at the threshold
  /// DOES match — but the match comes from the count floor, not the
  /// metadata.
  func testAlbumTagAtThresholdIsWholeViaCount() {
    makeAlbum(id: "a-album-3-tracks", releaseType: "album", remoteSongCount: 3)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-album-3-tracks"])
  }

  // MARK: - wholeAlbum(minSongCount:) — nil metadata (the majority case)

  /// **Happy path for the majority of a typical Navidrome library:**
  /// `getAlbumList2` emits no `releaseTypes` field, so most albums arrive
  /// with `releaseType == nil`. A nil-metadata album with enough tracks
  /// must match.
  func testNilReleaseTypeWithCountAboveThresholdIsWhole() {
    makeAlbum(id: "a-nil-5", releaseType: nil, remoteSongCount: 5)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-nil-5"])
  }

  /// **Regression guard for the SQLite NULL-handling pitfall.**
  ///
  /// A naive predicate of the form
  /// `NOT (releaseType CONTAINS[c] 'single') AND remoteSongCount >= 3`
  /// evaluates to NULL (not true) when `releaseType` is nil, because
  /// `NULL CONTAINS[c] 'single'` is NULL and `NOT NULL` is NULL, so the
  /// whole conjunction short-circuits to NULL — silently excluding the row
  /// from the result set. This was the underlying second bug that shipped
  /// in builds 2–4.
  ///
  /// The `releaseType == nil OR ...` guard in
  /// `WholeAlbumPredicates.wholeAlbum(minSongCount:)` is load-bearing: it
  /// short-circuits the OR before the NULL-poisoned branch is evaluated.
  /// This test seeds a nil-metadata album at exactly the threshold and
  /// asserts it is visible to the filter.
  func testNilReleaseTypeNotExcludedBySqliteNullPitfall() {
    makeAlbum(id: "a-nil-3", releaseType: nil, remoteSongCount: 3)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(
      matched,
      ["a-nil-3"],
      "Nil-metadata albums at threshold must match — regression guard for the SQLite NULL-handling pitfall"
    )
  }

  /// Nil metadata below threshold must NOT match.
  func testNilReleaseTypeBelowThresholdIsNotWhole() {
    makeAlbum(id: "a-nil-2", releaseType: nil, remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, [])
  }

  // MARK: - wholeAlbum(minSongCount:) — other metadata values

  /// Multi-value metadata like `"album ep"` matches via the count floor
  /// (it does not contain `"single"`, and count passes).
  func testMultiValueReleaseTypeIsWholeViaCount() {
    makeAlbum(id: "a-album-ep", releaseType: "album ep", remoteSongCount: 4)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-album-ep"])
  }

  /// A `"compilation"` tag with `remoteSongCount >= threshold` matches
  /// via the count floor. Compilations flow through the same rule as
  /// regular albums.
  func testCompilationAtThresholdIsWholeViaCount() {
    makeAlbum(id: "a-comp-6", releaseType: "compilation", remoteSongCount: 6)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, ["a-comp-6"])
  }

  /// A `"compilation"` tag below threshold does not match — the count
  /// floor applies regardless of metadata.
  func testCompilationBelowThresholdIsNotWhole() {
    makeAlbum(id: "a-comp-2", releaseType: "compilation", remoteSongCount: 2)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "a-"
    )
    XCTAssertEqual(matched, [])
  }

  // MARK: - Mixed-library smoke test

  /// Seeds a library with every interesting case in one go and asserts the
  /// filtered result set is exactly the expected whole albums.
  func testMixedLibraryFilter() {
    makeAlbum(id: "m-single-5", releaseType: "single", remoteSongCount: 5) // no (veto)
    makeAlbum(id: "m-album-1", releaseType: "album", remoteSongCount: 1) // no (count)
    makeAlbum(id: "m-ep-2", releaseType: "ep", remoteSongCount: 2) // no (count)
    makeAlbum(id: "m-album-3", releaseType: "album", remoteSongCount: 3) // yes (count)
    makeAlbum(id: "m-nil-3", releaseType: nil, remoteSongCount: 3) // yes (count + NULL guard)
    makeAlbum(id: "m-nil-1", releaseType: nil, remoteSongCount: 1) // no (count)
    makeAlbum(id: "m-comp-12", releaseType: "compilation", remoteSongCount: 12) // yes (count)
    library.saveContext()

    let matched = fetchAlbumIds(
      matching: WholeAlbumPredicates.wholeAlbum(minSongCount: 3),
      withPrefix: "m-"
    )
    XCTAssertEqual(matched, ["m-album-3", "m-comp-12", "m-nil-3"])
  }

  // MARK: - songFromNonWholeAlbum(minSongCount:)

  /// Songs attached to a `"single"`-tagged album (regardless of track
  /// count) are matched as coming from a non-whole album.
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

  /// Songs attached to an `"album"`-tagged parent with enough tracks are
  /// NOT matched by the non-whole-album predicate.
  func testSongFromAlbumTaggedAlbumWithEnoughTracksDoesNotMatch() {
    let album = makeAlbum(id: "s-album", releaseType: "album", remoteSongCount: 10)
    let song = library.createSong(account: account)
    song.id = "song-from-album"
    song.album = album
    library.saveContext()

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 3)
    let matched = try! testContext.fetch(fetchRequest)
      .map { $0.id }
      .filter { $0 == "song-from-album" }
    XCTAssertEqual(matched, [])
  }

  /// Songs attached to a nil-metadata parent whose `remoteSongCount` meets
  /// the threshold are NOT matched by the non-whole-album predicate — and,
  /// critically, the SQLite NULL pitfall does not silently flip the result.
  /// Inverse regression guard for
  /// `testNilReleaseTypeNotExcludedBySqliteNullPitfall`.
  func testSongFromNilMetadataParentAtThresholdDoesNotMatch() {
    let album = makeAlbum(id: "s-nil-3", releaseType: nil, remoteSongCount: 3)
    let song = library.createSong(account: account)
    song.id = "song-from-nil-3"
    song.album = album
    library.saveContext()

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 3)
    let matched = try! testContext.fetch(fetchRequest)
      .map { $0.id }
      .filter { $0 == "song-from-nil-3" }
    XCTAssertEqual(
      matched,
      [],
      "Nil-metadata parent at threshold is a whole album — its songs must NOT be in the non-whole result"
    )
  }

  /// Songs attached to a nil-metadata parent below threshold ARE matched
  /// by the non-whole-album predicate.
  func testSongFromNilMetadataParentBelowThresholdMatches() {
    let album = makeAlbum(id: "s-nil-1", releaseType: nil, remoteSongCount: 1)
    let song = library.createSong(account: account)
    song.id = "song-from-nil-1"
    song.album = album
    library.saveContext()

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 3)
    let matched = try! testContext.fetch(fetchRequest)
      .map { $0.id }
      .filter { $0 == "song-from-nil-1" }
    XCTAssertEqual(matched, ["song-from-nil-1"])
  }
}
