//
//  TrackAdjacencyStoreTest.swift
//  AmperfyKitTests
//
//  Tests for the Track Adjacency Engine v2 (protocol-based architecture).
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

// MARK: - TrackAdjacencyScoreTest

@MainActor
class TrackAdjacencyScoreTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var service: DefaultTrackAdjacencyService!
  var storageDirectory: URL!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_adjacency_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    let context = coreDataHelper.persistentContainer.viewContext
    service = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context }
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: storageDirectory)
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

  private func computeAndGetScore(_ songIdA: String, _ songIdB: String) -> ScoredRelation? {
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()
    return service.score(for: songIdA, songIdB)
  }

  // MARK: - Test 1: Two tracks at +/-1 in single playlist -> 3.5

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

  // MARK: - Test 2: Two tracks at +/-2 in single playlist -> 2.5

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

  // MARK: - Test 3: Same playlist, distance > 2 but within window -> 0.5

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

  // MARK: - Test 4: Same album, no shared playlist -> nil

  func testSameAlbumNoSharedPlaylist() {
    let album = makeAlbum(id: "t4-album")
    let songA = makeSong(id: "t4-a", album: album)
    let songB = makeSong(id: "t4-b", album: album)
    let otherSong = makeSong(id: "t4-other")
    makePlaylist(id: "t4-pl1", name: "Playlist A", songs: [songA, otherSong])
    makePlaylist(id: "t4-pl2", name: "Playlist B", songs: [songB, otherSong])

    let score = computeAndGetScore("t4-a", "t4-b")
    XCTAssertNil(score, "Album-only pair with no playlist co-membership should have no score")
  }

  // MARK: - Test 5: +/-1 in playlist AND same album -> 5.0

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

  // MARK: - Test 6: +/-1 in 3 playlists, same album -> 12.0

  func testAdjacentInThreePlaylistsSameAlbum() {
    let album = makeAlbum(id: "t6-album")
    let songA = makeSong(id: "t6-a", album: album)
    let songB = makeSong(id: "t6-b", album: album)
    makePlaylist(id: "t6-pl1", name: "Playlist 1", songs: [songA, songB])
    makePlaylist(id: "t6-pl2", name: "Playlist 2", songs: [songA, songB])
    makePlaylist(id: "t6-pl3", name: "Playlist 3", songs: [songA, songB])

    let score = computeAndGetScore("t6-a", "t6-b")
    XCTAssertNotNil(score)
    XCTAssertEqual(score!.coMembership, 1.5, accuracy: 0.001)
    XCTAssertEqual(score!.adjacency, 9.0, accuracy: 0.001)
    XCTAssertEqual(score!.album, 1.5, accuracy: 0.001)
    XCTAssertEqual(score!.total, 12.0, accuracy: 0.001)
  }

  // MARK: - Test 7: Symmetry

  func testSymmetry() {
    let songA = makeSong(id: "t7-a")
    let songB = makeSong(id: "t7-b")
    makePlaylist(id: "t7-pl", name: "Test 7", songs: [songA, songB])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let scoreAB = service.score(for: "t7-a", "t7-b")
    let scoreBA = service.score(for: "t7-b", "t7-a")
    XCTAssertEqual(scoreAB?.total, scoreBA?.total)
    XCTAssertEqual(scoreAB?.adjacency, scoreBA?.adjacency)
    XCTAssertEqual(scoreAB?.coMembership, scoreBA?.coMembership)
    XCTAssertEqual(scoreAB?.album, scoreBA?.album)
  }

  // MARK: - Test 8: No shared context -> nil

  func testNoSharedContextReturnsNil() {
    let songA = makeSong(id: "t8-a")
    let songB = makeSong(id: "t8-b")
    let songC = makeSong(id: "t8-c")
    makePlaylist(id: "t8-pl1", name: "Playlist A", songs: [songA, songC])
    makePlaylist(id: "t8-pl2", name: "Playlist B", songs: [songB, songC])

    let score = computeAndGetScore("t8-a", "t8-b")
    XCTAssertNil(score, "Songs with no shared playlist or album should have no score")
  }

  // MARK: - Test 9: Single-track playlist -> no data

  func testSingleTrackPlaylistProducesZeroPairs() {
    let songA = makeSong(id: "t9-a")
    makePlaylist(id: "t9-pl", name: "Solo", songs: [songA])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    XCTAssertFalse(service.hasData(for: "t9-a"))
  }

  // MARK: - Test 10: Duplicate track uses first occurrence only

  func testDuplicateTrackUsesFirstOccurrenceOnly() {
    let songA = makeSong(id: "t10-a")
    let songB = makeSong(id: "t10-b")
    let songC = makeSong(id: "t10-c")
    let playlist = library.createPlaylist(account: account)
    playlist.id = "t10-pl"
    playlist.name = "Dupe Test"
    playlist.append(playable: songA)
    playlist.append(playable: songB)
    playlist.append(playable: songC)
    playlist.append(playable: songA) // duplicate
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let scoreAB = service.score(for: "t10-a", "t10-b")
    XCTAssertNotNil(scoreAB)
    XCTAssertEqual(scoreAB!.total, 3.5, accuracy: 0.001)

    let scoreAC = service.score(for: "t10-a", "t10-c")
    XCTAssertNotNil(scoreAC)
    XCTAssertEqual(scoreAC!.total, 2.5, accuracy: 0.001)

    let scoreBC = service.score(for: "t10-b", "t10-c")
    XCTAssertNotNil(scoreBC)
    XCTAssertEqual(scoreBC!.total, 3.5, accuracy: 0.001)
  }

  // MARK: - Test 11: Smart playlists excluded

  func testSmartPlaylistsExcluded() {
    let songA = makeSong(id: "t11-a")
    let songB = makeSong(id: "t11-b")
    makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto",
      name: "Auto Mix",
      songs: [songA, songB]
    )
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let score = service.score(for: "t11-a", "t11-b")
    XCTAssertNil(score, "Smart playlist tracks should not contribute to scores")
  }
}

// MARK: - TrackAdjacencyIntegrationTest

@MainActor
class TrackAdjacencyIntegrationTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var service: DefaultTrackAdjacencyService!
  var storageDirectory: URL!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_adjacency_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    let context = coreDataHelper.persistentContainer.viewContext
    service = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context }
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: storageDirectory)
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

  // MARK: - Test 12: Empty-ish compute -> no crash

  func testEmptyLibraryComputeProducesNoCrash() {
    service.invalidate()
    service.computeFromScratch()
    XCTAssertFalse(service.isStale)
  }

  // MARK: - Test 13: 10-track playlist pair counts (windowed)

  func testSingleTenTrackPlaylistPairCounts() {
    var songs: [Song] = []
    for index in 0 ..< 10 {
      songs.append(makeSong(id: "t13-s\(index)"))
    }
    makePlaylist(id: "t13-pl", name: "Ten Tracks", songs: songs)
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    // With window=10, all 10 songs are within window -> C(10,2) = 45 pairs
    var pairCount = 0
    for indexI in 0 ..< 10 {
      for indexJ in (indexI + 1) ..< 10 {
        let score = service.score(for: "t13-s\(indexI)", "t13-s\(indexJ)")
        if score != nil { pairCount += 1 }
      }
    }
    XCTAssertEqual(pairCount, 45, "Should have C(10,2) = 45 pairs within window of 10")

    // Adjacency pairs at +/-1: 9 pairs
    for index in 0 ..< 9 {
      let score = service.score(for: "t13-s\(index)", "t13-s\(index + 1)")!
      XCTAssertEqual(score.adjacency, 3.0, accuracy: 0.001)
    }

    // Adjacency pairs at +/-2: 8 pairs
    for index in 0 ..< 8 {
      let score = service.score(for: "t13-s\(index)", "t13-s\(index + 2)")!
      XCTAssertEqual(score.adjacency, 2.0, accuracy: 0.001)
    }
  }

  // MARK: - Test 14: Album bonus counted exactly once

  func testAlbumBonusCountedOnce() {
    let album = makeAlbum(id: "t14-album")
    let songA = makeSong(id: "t14-a", album: album)
    let songB = makeSong(id: "t14-b", album: album)
    for playlistIndex in 0 ..< 5 {
      makePlaylist(
        id: "t14-pl\(playlistIndex)",
        name: "Playlist \(playlistIndex)",
        songs: [songA, songB]
      )
    }
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let score = service.score(for: "t14-a", "t14-b")!
    XCTAssertEqual(score.album, 1.5, accuracy: 0.001)
    XCTAssertEqual(score.coMembership, 2.5, accuracy: 0.001)
    XCTAssertEqual(score.adjacency, 15.0, accuracy: 0.001)
    XCTAssertEqual(score.total, 19.0, accuracy: 0.001)
  }

  // MARK: - Test 15: Score decomposition

  func testScoreDecomposition() {
    let album = makeAlbum(id: "t15-album")
    let songA = makeSong(id: "t15-a", album: album)
    let songB = makeSong(id: "t15-b", album: album)
    makePlaylist(id: "t15-pl", name: "Decompose", songs: [songA, songB])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let score = service.score(for: "t15-a", "t15-b")!
    XCTAssertEqual(score.adjacency, 3.0, accuracy: 0.001)
    XCTAssertEqual(score.coMembership, 0.5, accuracy: 0.001)
    XCTAssertEqual(score.album, 1.5, accuracy: 0.001)
    XCTAssertEqual(score.total, score.adjacency + score.coMembership + score.album, accuracy: 0.001)
  }

  // MARK: - Test 16: topRelated sorted descending

  func testTopRelatedReturnsTopNSortedDescending() {
    let songSeed = makeSong(id: "t16-seed")
    var allSongs: [Song] = []
    for index in 0 ..< 15 {
      allSongs.append(makeSong(id: "t16-s\(index)"))
    }
    for index in 0 ..< 5 {
      makePlaylist(
        id: "t16-adj\(index)",
        name: "Adjacent \(index)",
        songs: [songSeed, allSongs[index]]
      )
    }
    let coMemberSongs = [songSeed] + Array(allSongs[5 ..< 15])
    makePlaylist(id: "t16-comember", name: "Co-member", songs: coMemberSongs)
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let topTen = service.topRelated(for: "t16-seed", limit: 10)
    XCTAssertEqual(topTen.count, 10)

    for index in 0 ..< (topTen.count - 1) {
      XCTAssertGreaterThanOrEqual(
        topTen[index].score.total,
        topTen[index + 1].score.total,
        "Results should be sorted descending by total score"
      )
    }
  }

  // MARK: - Test 17: Invalidation and recompute

  func testInvalidationAndRecompute() {
    let songA = makeSong(id: "t17-a")
    let songB = makeSong(id: "t17-b")
    let songC = makeSong(id: "t17-c")
    makePlaylist(id: "t17-pl", name: "Original", songs: [songA, songB])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let scoreBefore = service.score(for: "t17-a", "t17-b")
    XCTAssertNotNil(scoreBefore)
    XCTAssertNil(service.score(for: "t17-a", "t17-c"))

    makePlaylist(id: "t17-pl2", name: "New", songs: [songA, songC])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    XCTAssertFalse(service.isStale)
    XCTAssertNotNil(service.score(for: "t17-a", "t17-c"), "New pair should appear after recompute")
  }

  // MARK: - Test 18: SQLite persistence round-trip

  func testSQLiteRoundTrip() {
    let songA = makeSong(id: "t18-a")
    let songB = makeSong(id: "t18-b")
    makePlaylist(id: "t18-pl", name: "Persist", songs: [songA, songB])
    library.saveContext()
    service.invalidate()
    service.computeFromScratch()

    let originalScore = service.score(for: "t18-a", "t18-b")!

    // Create a fresh service pointing to the same directory
    let context = coreDataHelper.persistentContainer.viewContext
    let freshService = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context }
    )

    let loadedScore = freshService.score(for: "t18-a", "t18-b")
    XCTAssertNotNil(loadedScore)
    XCTAssertEqual(loadedScore!.adjacency, originalScore.adjacency, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.coMembership, originalScore.coMembership, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.album, originalScore.album, accuracy: 0.001)
    XCTAssertEqual(loadedScore!.total, originalScore.total, accuracy: 0.001)
  }
}

// MARK: - TrackAdjacencyWindowTest

@MainActor
class TrackAdjacencyWindowTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var storageDirectory: URL!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_adjacency_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: storageDirectory)
  }

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
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

  // MARK: - Test 19: Songs beyond window size get no score

  func testSongsBeyondWindowGetNoScore() {
    // Create 15 songs in one playlist, use window=5
    var songs: [Song] = []
    for index in 0 ..< 15 {
      songs.append(makeSong(id: "tw-s\(index)"))
    }
    makePlaylist(id: "tw-pl", name: "Long Playlist", songs: songs)
    library.saveContext()

    let context = coreDataHelper.persistentContainer.viewContext
    let smallWindowComputer = LocalTrackAdjacencyComputer(windowSize: 5, playlistBatchSize: 20)
    let service = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context },
      computer: smallWindowComputer
    )
    service.invalidate()
    service.computeFromScratch()

    // Songs at distance 1 should have a score
    let scoreAdjacent = service.score(for: "tw-s0", "tw-s1")
    XCTAssertNotNil(scoreAdjacent)

    // Songs at distance 4 (within window of 5) should have a score
    let scoreInWindow = service.score(for: "tw-s0", "tw-s4")
    XCTAssertNotNil(scoreInWindow)

    // Songs at distance 5 (outside window of 5) should have NO score
    let scoreBeyondWindow = service.score(for: "tw-s0", "tw-s5")
    XCTAssertNil(scoreBeyondWindow, "Songs beyond window should have no score")

    // Songs at distance 10 should definitely have no score
    let scoreFarApart = service.score(for: "tw-s0", "tw-s10")
    XCTAssertNil(scoreFarApart, "Distant songs should have no score with small window")
  }

  // MARK: - Test 20: Playlist co-occurrence count

  func testPlaylistCoOccurrenceCount() {
    let songA = makeSong(id: "tco-a")
    let songB = makeSong(id: "tco-b")
    // Put in 3 playlists
    for playlistIndex in 0 ..< 3 {
      makePlaylist(
        id: "tco-pl\(playlistIndex)",
        name: "Playlist \(playlistIndex)",
        songs: [songA, songB]
      )
    }
    library.saveContext()

    let context = coreDataHelper.persistentContainer.viewContext
    let service = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context }
    )
    service.invalidate()
    service.computeFromScratch()

    let count = service.playlistCoOccurrenceCount(songIdA: "tco-a", songIdB: "tco-b")
    XCTAssertEqual(count, 3, "Should report 3 playlists co-containing both songs")
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

  // MARK: - Test 21: 50 playlists x 30 tracks performance

  func testPerformance50PlaylistsTimes30Tracks() {
    var allSongs: [Song] = []
    for songIndex in 0 ..< 150 {
      let song = library.createSong(account: account)
      song.id = "perf-s\(songIndex)"
      allSongs.append(song)
    }

    for playlistIndex in 0 ..< 50 {
      let playlist = library.createPlaylist(account: account)
      playlist.id = "perf-pl\(playlistIndex)"
      playlist.name = "Perf Playlist \(playlistIndex)"
      let startIndex = (playlistIndex * 3) % allSongs.count
      for offset in 0 ..< 30 {
        let songIndex = (startIndex + offset) % allSongs.count
        playlist.append(playable: allSongs[songIndex])
      }
    }
    library.saveContext()

    let storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_perf_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: storageDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: storageDirectory) }

    let context = coreDataHelper.persistentContainer.viewContext
    let service = DefaultTrackAdjacencyService(
      storageDirectory: storageDirectory,
      contextProvider: { context }
    )

    measure {
      service.invalidate()
      service.computeFromScratch()
    }

    XCTAssertTrue(service.hasData(for: "perf-s0"), "Performance test should produce scored pairs")
  }
}
