//
//  GetRandomWholeAlbumsTest.swift
//  AmperfyKitTests
//
//  Created by implementer-amperfy on 2026-04-15 (Release 1, PR 16).
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

/// Unit tests for `LibraryStorage.getRandomWholeAlbums(for:count:onlyCached:)`
/// — the PR 16 variant of the existing `getRandomAlbums` that filters via
/// `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)` and applies a
/// double-counting weight to albums with more than half their tracks
/// unplayed. See `spike/amperfy/BACKLOG.md` §16 and the PR 16 section of
/// `DESIGN_REVIEW_RELEASE_1.md` for the decision log.
@MainActor
class GetRandomWholeAlbumsTest: XCTestCase {
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

  /// Creates an album with the given identifier (mapped to `Album.name`,
  /// which is the album's `identifier`), a `remoteSongCount`, and `songs`
  /// whose `playCount` values are supplied explicitly. A nil `releaseType`
  /// is used so the whole-album predicate classifies purely by count.
  @discardableResult
  private func makeAlbum(
    name albumName: String,
    remoteSongCount: Int,
    playCounts: [Int]
  )
    -> Album {
    let album = library.createAlbum(account: account)
    album.id = albumName
    album.name = albumName
    album.releaseType = nil
    album.remoteSongCount = remoteSongCount
    for (index, playCount) in playCounts.enumerated() {
      let song = library.createSong(account: account)
      song.id = "\(albumName)-song-\(index)"
      song.album = album
      song.playCount = playCount
      song.track = index + 1
    }
    return album
  }

  /// Returns the album identifiers for the current test, filtered to the
  /// names that the test explicitly seeded. The seeded library may contain
  /// shared fixture albums from `CoreDataSeeder` that we do not care about.
  private func onlyOurs(_ results: [Album], in seededNames: Set<String>) -> [String] {
    results.map { $0.identifier }.filter { seededNames.contains($0) }
  }

  // MARK: - whole-album filter

  /// Singles and sub-3-track releases are excluded entirely regardless of
  /// play history. Mirrors `WholeAlbumPredicatesTest`'s count-floor cases
  /// but exercises the helper end-to-end.
  func testSingleAndShortAlbumsAreExcluded() {
    makeAlbum(name: "grwa-single-veto", remoteSongCount: 5, playCounts: [0, 0, 0, 0, 0])
      .releaseType = "single"
    makeAlbum(name: "grwa-two-tracks", remoteSongCount: 2, playCounts: [0, 0])
    makeAlbum(name: "grwa-three-tracks", remoteSongCount: 3, playCounts: [0, 0, 0])
    library.saveContext()

    let results = library.getRandomWholeAlbums(for: account, count: 10, onlyCached: false)
    let seededNames: Set<String> = ["grwa-single-veto", "grwa-two-tracks", "grwa-three-tracks"]
    XCTAssertEqual(
      Set(onlyOurs(results, in: seededNames)),
      ["grwa-three-tracks"],
      "Only the 3-track non-single album should survive the whole-album filter"
    )
  }

  // MARK: - weighting + dedup (100 iterations)

  /// Seed a fixture with four groups of whole albums differing only in play
  /// history, run the helper 100 times asking for a generous count, and
  /// assert the weighting + dedup contract.
  ///
  /// Seed shape:
  /// * 3 "fully played" albums — every track has `playCount > 0`
  /// * 3 "majority unplayed" albums — 3-of-4 tracks unplayed (> 50%, weighted 2×)
  /// * 3 "exactly half unplayed" albums — 2-of-4 tracks unplayed
  ///   (NOT weighted — boundary is strict ">")
  /// * 3 "minority unplayed" albums — 1-of-4 tracks unplayed
  ///
  /// Contract:
  /// * (a) majority-unplayed albums appear roughly 2× as often as the other
  ///       three groups (tolerated band: 1.5×–3.0× vs each other group);
  /// * (b) no single result set contains duplicates (dedup guarantee);
  /// * (c) half-unplayed and minority-unplayed groups appear at parity
  ///       (strict ">" boundary — half is single-counted).
  func testWeightingAndDedupOver100Iterations() {
    var seededNames = Set<String>()

    // Fully played (0 unplayed / 4)
    for index in 0 ..< 3 {
      let name = "grwa-fully-\(index)"
      seededNames.insert(name)
      makeAlbum(name: name, remoteSongCount: 4, playCounts: [2, 3, 1, 1])
    }
    // Majority unplayed (3 unplayed / 4 — strictly > 2)
    for index in 0 ..< 3 {
      let name = "grwa-majority-\(index)"
      seededNames.insert(name)
      makeAlbum(name: name, remoteSongCount: 4, playCounts: [0, 0, 0, 5])
    }
    // Exactly half unplayed (2 unplayed / 4 — NOT weighted)
    for index in 0 ..< 3 {
      let name = "grwa-half-\(index)"
      seededNames.insert(name)
      makeAlbum(name: name, remoteSongCount: 4, playCounts: [0, 0, 2, 3])
    }
    // Minority unplayed (1 unplayed / 4)
    for index in 0 ..< 3 {
      let name = "grwa-minority-\(index)"
      seededNames.insert(name)
      makeAlbum(name: name, remoteSongCount: 4, playCounts: [0, 1, 2, 3])
    }
    library.saveContext()

    var appearanceCounts: [String: Int] = [:]
    let iterations = 100
    let countPerCall = 6
    for _ in 0 ..< iterations {
      let result = library.getRandomWholeAlbums(
        for: account,
        count: countPerCall,
        onlyCached: false
      )
      // Filter to the albums we seeded (ignore any shared fixture albums).
      let ours = result.filter { seededNames.contains($0.identifier) }

      // (b) no duplicates within a single result set.
      let uniqueIdentifiers = Set(ours.map { $0.identifier })
      XCTAssertEqual(
        uniqueIdentifiers.count,
        ours.count,
        "A single refresh must never list the same album twice"
      )

      for album in ours {
        appearanceCounts[album.identifier, default: 0] += 1
      }
    }

    let totalFor = { (prefix: String) -> Int in
      seededNames
        .filter { $0.hasPrefix(prefix) }
        .reduce(0) { $0 + (appearanceCounts[$1] ?? 0) }
    }
    let fullyTotal = totalFor("grwa-fully-")
    let majorityTotal = totalFor("grwa-majority-")
    let halfTotal = totalFor("grwa-half-")
    let minorityTotal = totalFor("grwa-minority-")

    // (a) majority-unplayed albums should appear roughly 2× as often as
    //     each of the other three groups. Generous tolerances to keep the
    //     test deterministic-ish without flake.
    let baselineGroups: [(String, Int)] = [
      ("fully", fullyTotal),
      ("half", halfTotal),
      ("minority", minorityTotal),
    ]
    for (label, groupTotal) in baselineGroups {
      XCTAssertGreaterThan(
        groupTotal,
        0,
        "Group '\(label)' should still appear in the random selection (soft bias, not hard filter)"
      )
      let ratio = Double(majorityTotal) / Double(max(groupTotal, 1))
      XCTAssertGreaterThan(
        ratio,
        1.4,
        "Majority-unplayed albums (\(majorityTotal)) should be at least ~1.5× as frequent as '\(label)' (\(groupTotal))"
      )
      XCTAssertLessThan(
        ratio,
        3.2,
        "Majority-unplayed albums should not run away from the pool (~2× expected, ratio=\(ratio))"
      )
    }

    // (c) half-unplayed and minority-unplayed groups appear at parity
    //     (within a wide tolerance — 100 iterations is noisy).
    let parityRatio = Double(halfTotal) / Double(max(minorityTotal, 1))
    XCTAssertGreaterThan(
      parityRatio,
      0.55,
      "Half-unplayed group (\(halfTotal)) should appear near parity with minority-unplayed (\(minorityTotal)) — strict '>' boundary means half is single-counted"
    )
    XCTAssertLessThan(
      parityRatio,
      1.8,
      "Half-unplayed group should appear near parity with minority-unplayed, not 2×"
    )
  }

  // MARK: - partial-library behaviour

  /// When fewer than `count` whole albums exist, return what is available
  /// without relaxing the predicate.
  func testPartialLibraryReturnsWhatIsAvailable() {
    makeAlbum(name: "grwa-partial-a", remoteSongCount: 3, playCounts: [0, 0, 0])
    makeAlbum(name: "grwa-partial-b", remoteSongCount: 4, playCounts: [0, 0, 0, 1])
    makeAlbum(name: "grwa-partial-short", remoteSongCount: 2, playCounts: [0, 0])
    library.saveContext()

    let seededNames: Set<String> = [
      "grwa-partial-a",
      "grwa-partial-b",
      "grwa-partial-short",
    ]
    let results = library.getRandomWholeAlbums(for: account, count: 10, onlyCached: false)
    let ours = Set(onlyOurs(results, in: seededNames))
    XCTAssertEqual(
      ours,
      ["grwa-partial-a", "grwa-partial-b"],
      "Only the two whole albums should be returned — the predicate must not be relaxed"
    )
  }
}
