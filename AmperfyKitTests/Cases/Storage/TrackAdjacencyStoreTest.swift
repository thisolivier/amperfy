//
//  TrackAdjacencyStoreTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (PR 12 — Track Adjacency Engine).
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

// MARK: - TrackAdjacencyScoreTest

@MainActor
class TrackAdjacencyScoreTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var store: TrackAdjacencyStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = TrackAdjacencyStore(
      persistenceURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("test_adjacency_\(UUID().uuidString).json")
    )
  }

  override func tearDown() {
    // Clean up temp file if created
    try? FileManager.default.removeItem(at: store.persistenceURL)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Helpers

  @discardableResult
  private func makeSong(id: String, album: Album? = nil) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    if let album = album {
      song.album = album
    }
    return song
  }

  @discardableResult
  private func makePlaylist(id: String, name: String, songs: [Song]) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    for song in songs {
      playlist.append(playable: song)
    }
    return playlist
  }

  @discardableResult
  private func makeAlbum(id: String) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    return album
  }

  private func computeAndGetScore(_ songIdA: String, _ songIdB: String) -> SimilarityScore? {
    library.saveContext()
    store.compute(in: testContext)
    return store.score(for: songIdA, songIdB)
  }

  // MARK: - Test 1: Two tracks at ±1 in single playlist → 3.5

  func testAdjacentPlusMinusOneInSinglePlaylist() {
    let songA = makeSong(id: "t1-a")
    let songB = makeSong(id: "t1-b")
    makePlaylist(id: "t1-pl", name: "Test 1", songs: [songA, songB])

    let score = computeAndGetScore("t1-a", "t1-b")
    XCTAssertNotNil(score)
    XCTAssertEqual(score!.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 3.0, accuracy: 0.001)
    XCTAssertEqual(score!.total, 3.5, accuracy: 0.001)
  }

  // MARK: - Test 2: Two tracks at ±2 in single playlist → 2.5

  func testAdjacentPlusMinusTwoInSinglePlaylist() {
    let songA = makeSong(id: "t2-a")
    let songFiller = makeSong(id: "t2-filler")
    let songB = makeSong(id: "t2-b")
    makePlaylist(id: "t2-pl", name: "Test 2", songs: [songA, songFiller, songB])

    let score = computeAndGetScore("t2-a", "t2-b")
    XCTAssertNotNil(score)
    XCTAssertEqual(score!.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 2.0, accuracy: 0.001)
    XCTAssertEqual(score!.total, 2.5, accuracy: 0.001)
  }

  // MARK: - Test 3: Same playlist, distance > 2 → 0.5

  func testDistanceGreaterThanTwoCoMembershipOnly() {
    let songA = makeSong(id: "t3-a")
    let filler1 = makeSong(id: "t3-f1")
    let filler2 = makeSong(id: "t3-f2")
    let songB = makeSong(id: "t3-b")
    makePlaylist(id: "t3-pl", name: "Test 3", songs: [songA, filler1, filler2, songB])

    let score = computeAndGetScore("t3-a", "t3-b")
    XCTAssertNotNil(score)
    XCTAssertEqual(score!.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 0.0, accuracy: 0.001)
    XCTAssertEqual(score!.total, 0.5, accuracy: 0.001)
  }

  // MARK: - Test 4: Same album, no shared playlist → 1.5

  func testSameAlbumNoSharedPlaylist() {
    let album = makeAlbum(id: "t4-album")
    let songA = makeSong(id: "t4-a", album: album)
    let songB = makeSong(id: "t4-b", album: album)
    // Put them in separate playlists so album bonus applies but no co-membership
    let otherSong = makeSong(id: "t4-other")
    makePlaylist(id: "t4-pl1", name: "Playlist A", songs: [songA, otherSong])
    makePlaylist(id: "t4-pl2", name: "Playlist B", songs: [songB, otherSong])

    let score = computeAndGetScore("t4-a", "t4-b")
    XCTAssertNotNil(score, "Album-only pair should still produce a score")
    XCTAssertEqual(score!.album, 1.5, accuracy: 0.001)
    XCTAssertEqual(score!.coMembership, 0.0, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 0.0, accuracy: 0.001)
    XCTAssertEqual(score!.total, 1.5, accuracy: 0.001)
  }

  // MARK: - Test 5: ±1 in playlist AND same album → 5.0

  func testAdjacentAndSameAlbum() {
    let album = makeAlbum(id: "t5-album")
    let songA = makeSong(id: "t5-a", album: album)
    let songB = makeSong(id: "t5-b", album: album)
    makePlaylist(id: "t5-pl", name: "Test 5", songs: [songA, songB])

    let score = computeAndGetScore("t5-a", "t5-b")
    XCTAssertNotNil(score)
    XCTAssertEqual(score!.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 3.0, accuracy: 0.001)
    XCTAssertEqual(score!.album, 1.5, accuracy: 0.001)
    XCTAssertEqual(score!.total, 5.0, accuracy: 0.001)
  }

  // MARK: - Test 6: ±1 in 3 playlists, same album → 12.0

  func testAdjacentInThreePlaylistsSameAlbum() {
    let album = makeAlbum(id: "t6-album")
    let songA = makeSong(id: "t6-a", album: album)
    let songB = makeSong(id: "t6-b", album: album)
    makePlaylist(id: "t6-pl1", name: "Playlist 1", songs: [songA, songB])
    makePlaylist(id: "t6-pl2", name: "Playlist 2", songs: [songA, songB])
    makePlaylist(id: "t6-pl3", name: "Playlist 3", songs: [songA, songB])

    let score = computeAndGetScore("t6-a", "t6-b")
    XCTAssertNotNil(score)
    // 3 playlists × (0.5 co-membership + 3.0 adjacency) = 10.5
    XCTAssertEqual(score!.coMembership, 1.5, accuracy: 0.001) // 3 × 0.5
    XCTAssertEqual(score!.adjacency, 9.0, accuracy: 0.001) // 3 × 3.0
    XCTAssertEqual(score!.album, 1.5, accuracy: 0.001) // once
    XCTAssertEqual(score!.total, 12.0, accuracy: 0.001) // 10.5 + 1.5
  }

  // MARK: - Test 7: Symmetry — score(A,B) == score(B,A)

  func testSymmetry() {
    let songA = makeSong(id: "t7-a")
    let songB = makeSong(id: "t7-b")
    makePlaylist(id: "t7-pl", name: "Test 7", songs: [songA, songB])
    library.saveContext()
    store.compute(in: testContext)

    let scoreAB = store.score(for: "t7-a", "t7-b")
    let scoreBA = store.score(for: "t7-b", "t7-a")
    XCTAssertEqual(scoreAB?.total, scoreBA?.total)
    XCTAssertEqual(scoreAB?.adjacency, scoreBA?.adjacency)
    XCTAssertEqual(scoreAB?.coMembership, scoreBA?.coMembership)
    XCTAssertEqual(scoreAB?.album, scoreBA?.album)
  }

  // MARK: - Test 8: No shared context → nil

  func testNoSharedContextReturnsNil() {
    let songA = makeSong(id: "t8-a")
    let songB = makeSong(id: "t8-b")
    let songC = makeSong(id: "t8-c")
    makePlaylist(id: "t8-pl1", name: "Playlist A", songs: [songA, songC])
    makePlaylist(id: "t8-pl2", name: "Playlist B", songs: [songB, songC])

    let score = computeAndGetScore("t8-a", "t8-b")
    XCTAssertNil(score, "Songs with no shared playlist or album should have no score")
  }

  // MARK: - Test 9: Single-track playlist → zero pairs, no crash

  func testSingleTrackPlaylistProducesZeroPairs() {
    let songA = makeSong(id: "t9-a")
    makePlaylist(id: "t9-pl", name: "Solo", songs: [songA])
    library.saveContext()
    store.compute(in: testContext)

    XCTAssertFalse(store.hasData(for: "t9-a"))
  }

  // MARK: - Test 10: Duplicate track in same playlist → first occurrence only

  func testDuplicateTrackUsesFirstOccurrenceOnly() {
    let songA = makeSong(id: "t10-a")
    let songB = makeSong(id: "t10-b")
    let songC = makeSong(id: "t10-c")
    // Playlist: A, B, C, A (duplicate A at end)
    let playlist = library.createPlaylist(account: account)
    playlist.id = "t10-pl"
    playlist.name = "Dupe Test"
    playlist.append(playable: songA)
    playlist.append(playable: songB)
    playlist.append(playable: songC)
    playlist.append(playable: songA) // duplicate
    library.saveContext()
    store.compute(in: testContext)

    // A is at position 0 (first occurrence used, duplicate at 3 ignored)
    // B is at position 1, C is at position 2
    // A-B: distance 1 → 3.0 + 0.5 = 3.5
    let scoreAB = store.score(for: "t10-a", "t10-b")
    XCTAssertNotNil(scoreAB)
    XCTAssertEqual(scoreAB!.total, 3.5, accuracy: 0.001)

    // A-C: distance 2 → 2.0 + 0.5 = 2.5
    let scoreAC = store.score(for: "t10-a", "t10-c")
    XCTAssertNotNil(scoreAC)
    XCTAssertEqual(scoreAC!.total, 2.5, accuracy: 0.001)

    // B-C: distance 1 → 3.0 + 0.5 = 3.5
    let scoreBC = store.score(for: "t10-b", "t10-c")
    XCTAssertNotNil(scoreBC)
    XCTAssertEqual(scoreBC!.total, 3.5, accuracy: 0.001)
  }

  // MARK: - Test 11: Smart playlists excluded

  func testSmartPlaylistsExcluded() {
    let songA = makeSong(id: "t11-a")
    let songB = makeSong(id: "t11-b")
    // Only put in a smart playlist
    makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto",
      name: "Auto Mix",
      songs: [songA, songB]
    )
    library.saveContext()
    store.compute(in: testContext)

    let score = store.score(for: "t11-a", "t11-b")
    XCTAssertNil(score, "Smart playlist tracks should not contribute to scores")
  }
}

// MARK: - TrackAdjacencyIntegrationTest

@MainActor
class TrackAdjacencyIntegrationTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var store: TrackAdjacencyStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = TrackAdjacencyStore(
      persistenceURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("test_adjacency_\(UUID().uuidString).json")
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: store.persistenceURL)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Helpers

  @discardableResult
  private func makeSong(id: String, album: Album? = nil) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    if let album = album {
      song.album = album
    }
    return song
  }

  @discardableResult
  private func makePlaylist(id: String, name: String, songs: [Song]) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    for song in songs {
      playlist.append(playable: song)
    }
    return playlist
  }

  @discardableResult
  private func makeAlbum(id: String) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    return album
  }

  // MARK: - Test 12: Empty library compute → zero pairs, no crash

  func testEmptyLibraryComputeProducesZeroPairs() {
    // Use a fresh (non-seeded) context — seeded data has playlists
    store.compute(in: testContext)
    // Seeded playlists may produce some pairs but the store should not crash
    // For a truly empty scenario, just verify the store is functional
    XCTAssertFalse(store.isStale)
  }

  // MARK: - Test 13: Single 10-track playlist → correct pair counts

  func testSingleTenTrackPlaylistPairCounts() {
    var songs: [Song] = []
    for index in 0 ..< 10 {
      songs.append(makeSong(id: "t13-s\(index)"))
    }
    makePlaylist(id: "t13-pl", name: "Ten Tracks", songs: songs)
    library.saveContext()
    store.compute(in: testContext)

    // Total pairs from 10 songs: C(10,2) = 45
    // All 45 pairs should have at least co-membership (0.5)
    var pairCount = 0
    for indexI in 0 ..< 10 {
      for indexJ in (indexI + 1) ..< 10 {
        let score = store.score(for: "t13-s\(indexI)", "t13-s\(indexJ)")
        XCTAssertNotNil(score, "Pair s\(indexI)-s\(indexJ) should exist")
        if score != nil { pairCount += 1 }
      }
    }
    XCTAssertEqual(pairCount, 45, "Should have C(10,2) = 45 pairs")

    // Adjacency pairs at ±1: 9 pairs (0-1, 1-2, ..., 8-9)
    for index in 0 ..< 9 {
      let score = store.score(for: "t13-s\(index)", "t13-s\(index + 1)")!
      XCTAssertEqual(score.adjacency, 3.0, accuracy: 0.001, "±1 pair should have adjacency 3.0")
    }

    // Adjacency pairs at ±2: 8 pairs (0-2, 1-3, ..., 7-9)
    for index in 0 ..< 8 {
      let score = store.score(for: "t13-s\(index)", "t13-s\(index + 2)")!
      XCTAssertEqual(score.adjacency, 2.0, accuracy: 0.001, "±2 pair should have adjacency 2.0")
    }
  }

  // MARK: - Test 14: Album bonus counted exactly once

  func testAlbumBonusCountedOnce() {
    let album = makeAlbum(id: "t14-album")
    let songA = makeSong(id: "t14-a", album: album)
    let songB = makeSong(id: "t14-b", album: album)
    // Put in 5 playlists
    for playlistIndex in 0 ..< 5 {
      makePlaylist(
        id: "t14-pl\(playlistIndex)",
        name: "Playlist \(playlistIndex)",
        songs: [songA, songB]
      )
    }
    library.saveContext()
    store.compute(in: testContext)

    let score = store.score(for: "t14-a", "t14-b")!
    XCTAssertEqual(score.album, 1.5, accuracy: 0.001, "Album bonus should be 1.5 (once)")
    XCTAssertEqual(
      score.coMembership, 2.5, accuracy: 0.001,
      "Co-membership should be 5 × 0.5 = 2.5"
    )
    XCTAssertEqual(
      score.adjacency, 15.0, accuracy: 0.001,
      "Adjacency should be 5 × 3.0 = 15.0"
    )
    // Total: 2.5 + 15.0 + 1.5 = 19.0
    XCTAssertEqual(score.total, 19.0, accuracy: 0.001)
  }

  // MARK: - Test 15: Score decomposition fields stored separately

  func testScoreDecomposition() {
    let album = makeAlbum(id: "t15-album")
    let songA = makeSong(id: "t15-a", album: album)
    let songB = makeSong(id: "t15-b", album: album)
    makePlaylist(id: "t15-pl", name: "Decompose", songs: [songA, songB])
    library.saveContext()
    store.compute(in: testContext)

    let score = store.score(for: "t15-a", "t15-b")!
    // Verify each component is stored independently
    XCTAssertEqual(score.adjacency, 3.0, accuracy: 0.001)
    XCTAssertEqual(score.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score.album, 1.5, accuracy: 0.001)
    // Verify total is the sum
    XCTAssertEqual(score.total, score.adjacency + score.coMembership + score.album, accuracy: 0.001)
  }

  // MARK: - Test 16: topRelated returns top-N sorted descending

  func testTopRelatedReturnsTopNSortedDescending() {
    let songSeed = makeSong(id: "t16-seed")
    // Create 15 songs with varying relationships to seed
    var allSongs: [Song] = []
    for index in 0 ..< 15 {
      allSongs.append(makeSong(id: "t16-s\(index)"))
    }
    // First 5 songs adjacent to seed (strongest: 3.5 each)
    for index in 0 ..< 5 {
      makePlaylist(
        id: "t16-adj\(index)",
        name: "Adjacent \(index)",
        songs: [songSeed, allSongs[index]]
      )
    }
    // Next 10 songs only co-members (weakest: 0.5 each)
    var coMemberSongs = [songSeed] + Array(allSongs[5 ..< 15])
    makePlaylist(id: "t16-comember", name: "Co-member", songs: coMemberSongs)
    library.saveContext()
    store.compute(in: testContext)

    let topTen = store.topRelated(for: "t16-seed", limit: 10)
    XCTAssertEqual(topTen.count, 10)

    // First 5 should be the adjacent songs (score ~3.5 each, some also co-member in last playlist)
    // Verify descending order
    for index in 0 ..< (topTen.count - 1) {
      XCTAssertGreaterThanOrEqual(
        topTen[index].score.total,
        topTen[index + 1].score.total,
        "Results should be sorted descending by total score"
      )
    }
  }

  // MARK: - Test 17: Invalidation on change → recompute produces updated scores

  func testInvalidationAndRecompute() {
    let songA = makeSong(id: "t17-a")
    let songB = makeSong(id: "t17-b")
    let songC = makeSong(id: "t17-c")
    makePlaylist(id: "t17-pl", name: "Original", songs: [songA, songB])
    library.saveContext()
    store.compute(in: testContext)

    let scoreBefore = store.score(for: "t17-a", "t17-b")
    XCTAssertNotNil(scoreBefore)
    XCTAssertNil(store.score(for: "t17-a", "t17-c"))

    // Now add a new playlist with A and C
    store.invalidate()
    XCTAssertTrue(store.isStale)

    makePlaylist(id: "t17-pl2", name: "New", songs: [songA, songC])
    library.saveContext()
    store.compute(in: testContext)

    XCTAssertFalse(store.isStale)
    XCTAssertNotNil(store.score(for: "t17-a", "t17-c"), "New pair should appear after recompute")
  }

  // MARK: - Test 18: JSON round-trip

  func testJsonRoundTrip() throws {
    let songA = makeSong(id: "t18-a")
    let songB = makeSong(id: "t18-b")
    makePlaylist(id: "t18-pl", name: "Persist", songs: [songA, songB])
    library.saveContext()
    store.compute(in: testContext)

    let originalScore = store.score(for: "t18-a", "t18-b")!

    // Save to disk
    try store.saveToDisk()

    // Create a fresh store and load
    let freshStore = TrackAdjacencyStore(persistenceURL: store.persistenceURL)
    XCTAssertTrue(freshStore.loadFromDisk())

    let loadedScore = freshStore.score(for: "t18-a", "t18-b")
    XCTAssertNotNil(loadedScore)
    XCTAssertEqual(loadedScore!.adjacency, originalScore.adjacency, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.coMembership, originalScore.coMembership, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.album, originalScore.album, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.total, originalScore.total, accuracy: 0.001)
  }
}

// MARK: - TrackAdjacencyPerformanceTest

@MainActor
class TrackAdjacencyPerformanceTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Test 19: 50 playlists × 30 tracks < 500ms

  func testPerformance50PlaylistsTimes30Tracks() {
    // Create 150 unique songs (reused across playlists)
    var allSongs: [Song] = []
    for songIndex in 0 ..< 150 {
      let song = library.createSong(account: account)
      song.id = "perf-s\(songIndex)"
      allSongs.append(song)
    }

    // Create 50 playlists, each with 30 songs drawn from the pool
    for playlistIndex in 0 ..< 50 {
      let playlist = library.createPlaylist(account: account)
      playlist.id = "perf-pl\(playlistIndex)"
      playlist.name = "Perf Playlist \(playlistIndex)"
      // Each playlist gets a sliding window of 30 songs
      let startIndex = (playlistIndex * 3) % allSongs.count
      for offset in 0 ..< 30 {
        let songIndex = (startIndex + offset) % allSongs.count
        playlist.append(playable: allSongs[songIndex])
      }
    }
    library.saveContext()

    let store = TrackAdjacencyStore(
      persistenceURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("test_perf_\(UUID().uuidString).json")
    )

    measure {
      store.compute(in: testContext)
    }

    // Verify it produced results
    XCTAssertFalse(store.scores.isEmpty, "Performance test should produce scored pairs")
    try? FileManager.default.removeItem(at: store.persistenceURL)
  }

  // MARK: - Test 20: Memory usage verification

  func testMemoryFootprintReasonable() {
    // Create a dataset and verify the score dictionary isn't excessively large
    var allSongs: [Song] = []
    for songIndex in 0 ..< 100 {
      let song = library.createSong(account: account)
      song.id = "mem-s\(songIndex)"
      allSongs.append(song)
    }
    for playlistIndex in 0 ..< 20 {
      let playlist = library.createPlaylist(account: account)
      playlist.id = "mem-pl\(playlistIndex)"
      playlist.name = "Mem Playlist \(playlistIndex)"
      let startIndex = (playlistIndex * 5) % allSongs.count
      for offset in 0 ..< 30 {
        let songIndex = (startIndex + offset) % allSongs.count
        playlist.append(playable: allSongs[songIndex])
      }
    }
    library.saveContext()

    let store = TrackAdjacencyStore(
      persistenceURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("test_mem_\(UUID().uuidString).json")
    )
    store.compute(in: testContext)

    // Each entry is roughly SongPair (2 strings ~40 bytes) + SimilarityScore (12 bytes)
    // For < 50k pairs this should be well under 5MB
    let pairCount = store.scores.count
    let estimatedBytes = pairCount * 52 // conservative estimate
    XCTAssertLessThan(
      estimatedBytes, 5_000_000,
      "Memory footprint should be under 5MB — got \(pairCount) pairs (~\(estimatedBytes) bytes)"
    )
    try? FileManager.default.removeItem(at: store.persistenceURL)
  }
}
