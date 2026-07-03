//
//  DeckSeedResolverTest.swift
//  AmperfyKitTests
//
//  Tests for DeckSeed -> DeckSeedResolution (Discovery sprint D4), including
//  the new LibraryStorage getters it depends on:
//  getRecentlyPlayedSongs(for:limit:) and
//  getPlaylists(for:containingSongId:).
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

@MainActor
class DeckSeedResolverTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
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
    for song in songs { playlist.append(playable: song) }
    return playlist
  }

  @discardableResult
  private func makeAlbum(id: String, name: String, songs: [Song]) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.name = name
    for song in songs { song.album = album }
    return album
  }

  // MARK: - Playlist seed

  func testPlaylistSeedResolvesSongIdsAndTitle() {
    let songA = makeSong(id: "s-a")
    let songB = makeSong(id: "s-b")
    makePlaylist(id: "pl-1", name: "Late Night Drives", songs: [songA, songB])
    library.saveContext()

    let resolution = DeckSeedResolver.resolve(
      seed: .playlist(id: "pl-1"),
      storage: library,
      account: account
    )

    XCTAssertEqual(resolution.seedSongIds, ["s-a", "s-b"])
    XCTAssertEqual(resolution.seedCollectionId, "pl-1")
    XCTAssertEqual(resolution.seedTitle, "Late Night Drives")
  }

  func testPlaylistSeedDedupesRepeatedTracks() {
    let songA = makeSong(id: "s-a")
    let playlist = library.createPlaylist(account: account)
    playlist.id = "pl-2"
    playlist.name = "Repeats"
    playlist.append(playable: songA)
    playlist.append(playable: songA)
    library.saveContext()

    let resolution = DeckSeedResolver.resolve(
      seed: .playlist(id: "pl-2"),
      storage: library,
      account: account
    )

    XCTAssertEqual(resolution.seedSongIds, ["s-a"])
  }

  // MARK: - Album seed

  func testAlbumSeedResolvesSongIdsAndTitle() {
    let songA = makeSong(id: "s-a")
    let songB = makeSong(id: "s-b")
    makeAlbum(id: "al-1", name: "Night Mix", songs: [songA, songB])
    library.saveContext()

    let resolution = DeckSeedResolver.resolve(
      seed: .album(id: "al-1"),
      storage: library,
      account: account
    )

    XCTAssertEqual(Set(resolution.seedSongIds), ["s-a", "s-b"])
    XCTAssertEqual(resolution.seedCollectionId, "al-1")
    XCTAssertEqual(resolution.seedTitle, "Night Mix")
  }

  func testUnknownCollectionIdResolvesToEmptySongIds() {
    let resolution = DeckSeedResolver.resolve(
      seed: .album(id: "does-not-exist"),
      storage: library,
      account: account
    )

    XCTAssertTrue(resolution.seedSongIds.isEmpty)
    XCTAssertEqual(resolution.seedCollectionId, "does-not-exist")
  }

  // MARK: - History seed

  func testHistorySeedReturnsMostRecentlyPlayedFirstExcludingUnplayed() {
    let played1 = makeSong(id: "played-old")
    let played2 = makeSong(id: "played-new")
    let neverPlayed = makeSong(id: "never-played")
    played1.lastTimePlayed = Date(timeIntervalSince1970: 1000)
    played2.lastTimePlayed = Date(timeIntervalSince1970: 2000)
    _ = neverPlayed
    library.saveContext()

    let resolution = DeckSeedResolver.resolve(
      seed: .recentHistory,
      storage: library,
      account: account,
      historyLimit: 20
    )

    XCTAssertEqual(resolution.seedSongIds, ["played-new", "played-old"])
    XCTAssertNil(resolution.seedCollectionId)
    XCTAssertEqual(resolution.seedTitle, "your recent listening")
  }

  func testHistorySeedRespectsLimit() {
    for index in 0 ..< 5 {
      let song = makeSong(id: "h-\(index)")
      song.lastTimePlayed = Date(timeIntervalSince1970: Double(index))
    }
    library.saveContext()

    let resolution = DeckSeedResolver.resolve(
      seed: .recentHistory,
      storage: library,
      account: account,
      historyLimit: 2
    )

    XCTAssertEqual(resolution.seedSongIds.count, 2)
    XCTAssertEqual(resolution.seedSongIds, ["h-4", "h-3"])
  }

  // MARK: - Reverse lookup: playlists containing a song

  func testGetPlaylistsContainingSongIdFindsAllAndDedupes() {
    let songA = makeSong(id: "rev-a")
    let songB = makeSong(id: "rev-b")
    makePlaylist(id: "rev-pl1", name: "Playlist One", songs: [songA, songB])
    makePlaylist(id: "rev-pl2", name: "Playlist Two", songs: [songA])
    library.saveContext()

    let playlists = library.getPlaylists(for: account, containingSongId: "rev-a")
    XCTAssertEqual(Set(playlists.map(\.id)), ["rev-pl1", "rev-pl2"])

    let playlistsForB = library.getPlaylists(for: account, containingSongId: "rev-b")
    XCTAssertEqual(playlistsForB.map(\.id), ["rev-pl1"])

    let playlistsForUnknown = library.getPlaylists(for: account, containingSongId: "no-such-song")
    XCTAssertTrue(playlistsForUnknown.isEmpty)
  }
}
