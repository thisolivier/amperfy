//
//  OnDeviceAdventurousPoolProviderTest.swift
//  AmperfyKitTests
//
//  Tests for the track -> containing-collection mapping and aggregation
//  OnDeviceAdventurousPoolProvider builds on top of TrackAdjacencyQuerying
//  (Discovery sprint D4).
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
import XCTest

// MARK: - FakeTrackAdjacencyQuerying

private final class FakeTrackAdjacencyQuerying: TrackAdjacencyQuerying {
  var relatedBySeed: [String: [(songId: String, score: ScoredRelation)]] = [:]
  var songsWithData: Set<String> = []

  func topRelated(for songId: String, limit: Int) -> [(songId: String, score: ScoredRelation)] {
    Array((relatedBySeed[songId] ?? []).prefix(limit))
  }

  func hasData(for songId: String) -> Bool { songsWithData.contains(songId) }

  func score(for songIdA: String, _ songIdB: String) -> ScoredRelation? { nil }

  func playlistCoOccurrenceCount(songIdA: String, songIdB: String) -> Int { 0 }
}

private func relation(_ id1: String, _ id2: String, total: Float) -> ScoredRelation {
  ScoredRelation(songId1: id1, songId2: id2, adjacency: total)
}

// MARK: - OnDeviceAdventurousPoolProviderTest

@MainActor
class OnDeviceAdventurousPoolProviderTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  private var fakeService: FakeTrackAdjacencyQuerying!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    fakeService = FakeTrackAdjacencyQuerying()
  }

  private func makeSong(id: String, album: Album? = nil) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    if let album { song.album = album }
    return song
  }

  private func makeAlbum(id: String) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    return album
  }

  private func makePlaylist(id: String, songs: [Song]) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = id
    for song in songs { playlist.append(playable: song) }
    return playlist
  }

  private func makeProvider() -> OnDeviceAdventurousPoolProvider {
    OnDeviceAdventurousPoolProvider(
      storage: library,
      account: account,
      adjacencyService: fakeService
    )
  }

  // MARK: - dataAvailable

  func testDataUnavailableWhenNoSeedTrackHasData() {
    let seedSong = makeSong(id: "seed-song")
    _ = seedSong
    library.saveContext()

    let (results, dataAvailable) = makeProvider().candidates(
      seedSongIds: ["seed-song"],
      kind: .album,
      excluding: [],
      count: 10
    )

    XCTAssertTrue(results.isEmpty)
    XCTAssertFalse(dataAvailable)
  }

  func testDataAvailableWhenAtLeastOneSeedTrackHasDataEvenIfResultsEmpty() {
    let seedSong = makeSong(id: "seed-song")
    _ = seedSong
    fakeService.songsWithData = ["seed-song"]
    library.saveContext()

    let (results, dataAvailable) = makeProvider().candidates(
      seedSongIds: ["seed-song"],
      kind: .album,
      excluding: [],
      count: 10
    )

    XCTAssertTrue(results.isEmpty)
    XCTAssertTrue(dataAvailable)
  }

  // MARK: - Album mapping + aggregation

  func testMapsRelatedTracksToAlbumsAndSumsScores() {
    let albumX = makeAlbum(id: "album-x")
    let seedSong = makeSong(id: "seed-song")
    let cand1 = makeSong(id: "cand-1", album: albumX)
    let cand2 = makeSong(id: "cand-2", album: albumX) // same album as cand-1: scores should sum
    let albumY = makeAlbum(id: "album-y")
    let cand3 = makeSong(id: "cand-3", album: albumY)
    _ = (seedSong, cand1, cand2, cand3)
    library.saveContext()

    fakeService.songsWithData = ["seed-song"]
    fakeService.relatedBySeed["seed-song"] = [
      (songId: "cand-1", score: relation("seed-song", "cand-1", total: 5)),
      (songId: "cand-2", score: relation("seed-song", "cand-2", total: 3)),
      (songId: "cand-3", score: relation("seed-song", "cand-3", total: 4)),
    ]

    let (results, dataAvailable) = makeProvider().candidates(
      seedSongIds: ["seed-song"],
      kind: .album,
      excluding: [],
      count: 10
    )

    XCTAssertTrue(dataAvailable)
    let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.collectionId, $0.score) })
    XCTAssertEqual(byId["album-x"] ?? -1, 8, accuracy: 0.001, "cand-1 (5) + cand-2 (3) should sum")
    XCTAssertEqual(byId["album-y"] ?? -1, 4, accuracy: 0.001)
    // album-x should rank first (higher aggregated score)
    XCTAssertEqual(results.first?.collectionId, "album-x")
  }

  // MARK: - Playlist mapping via reverse lookup

  func testMapsRelatedTracksToContainingPlaylists() {
    let seedSong = makeSong(id: "seed-song")
    let candSong = makeSong(id: "cand-song")
    makePlaylist(id: "playlist-a", songs: [candSong])
    makePlaylist(id: "playlist-b", songs: [candSong])
    _ = seedSong
    library.saveContext()

    fakeService.songsWithData = ["seed-song"]
    fakeService.relatedBySeed["seed-song"] = [
      (songId: "cand-song", score: relation("seed-song", "cand-song", total: 6)),
    ]

    let (results, _) = makeProvider().candidates(
      seedSongIds: ["seed-song"],
      kind: .playlist,
      excluding: [],
      count: 10
    )

    XCTAssertEqual(Set(results.map(\.collectionId)), ["playlist-a", "playlist-b"])
    XCTAssertTrue(results.allSatisfy { $0.score == 6 })
  }

  // MARK: - Excluding

  func testExcludingFiltersOutGivenCollectionIds() {
    let albumX = makeAlbum(id: "album-x")
    let seedSong = makeSong(id: "seed-song")
    let cand1 = makeSong(id: "cand-1", album: albumX)
    _ = (seedSong, cand1)
    library.saveContext()

    fakeService.songsWithData = ["seed-song"]
    fakeService.relatedBySeed["seed-song"] = [
      (songId: "cand-1", score: relation("seed-song", "cand-1", total: 5)),
    ]

    let (results, _) = makeProvider().candidates(
      seedSongIds: ["seed-song"],
      kind: .album,
      excluding: ["album-x"],
      count: 10
    )

    XCTAssertTrue(results.isEmpty)
  }
}
