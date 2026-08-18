//
//  PlaylistSongAdderTest.swift
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

// MARK: - RECORDING_PlaylistAddSyncer

/// A `LibrarySyncer` that records `syncUpload(playlistToAddSongs:songs:)` calls
/// so the bulk-add path can be asserted end to end. All other protocol methods
/// are inert stubs. Can be told to throw from the add-songs upload to exercise
/// the failure ordering (local append must NOT run on a sync failure).
///
/// The codebase has no shared recording mock (the existing `SPY_LibrarySyncer`
/// only records album syncs), so this is built locally per the house
/// "define the mock in the test that needs it" convention.
@MainActor
final class RECORDING_PlaylistAddSyncer: LibrarySyncer {
  private(set) var addSongsCalls: [(playlistId: String, songIds: [String])] = []
  var uploadError: Error?

  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws {
    if let uploadError { throw uploadError }
    addSongsCalls.append((playlistId: playlist.id, songIds: songs.map(\.id)))
  }

  // MARK: Inert stubs

  func syncInitial(statusNotifyier: SyncCallbacks?) async throws {}
  func sync(genre: Genre) async throws {}
  func sync(artist: Artist) async throws {}
  func sync(album: Album) async throws {}
  func sync(song: Song) async throws {}
  func sync(podcast: Podcast) async throws {}
  func syncNewestPodcastEpisodes() async throws {}
  func syncNewestAlbums(offset: Int, count: Int) async throws {}
  func syncRecentAlbums(offset: Int, count: Int) async throws {}
  func syncAlbumListPage(offset: Int, count: Int) async throws -> Int { 0 }
  func syncFavoriteLibraryElements() async throws {}
  func syncRadios() async throws {}
  func syncDownPlaylistsWithoutSongs() async throws {}
  func syncDown(playlist: Playlist) async throws {}
  func syncUpload(playlistToUpdateName playlist: Playlist) async throws {}
  func syncUpload(playlistToDeleteSong playlist: Playlist, index: Int) async throws {}
  func syncUpload(playlistToUpdateOrder playlist: Playlist) async throws {}
  func syncUpload(playlistIdToDelete id: String) async throws {}
  func syncDownPodcastsWithoutEpisodes() async throws {}
  func searchArtists(searchText: String) async throws {}
  func searchAlbums(searchText: String) async throws {}
  func searchSongs(searchText: String) async throws {}
  func syncMusicFolders() async throws {}
  func syncIndexes(musicFolder: MusicFolder) async throws {}
  func sync(directory: Directory) async throws {}
  func requestRandomSongs(playlist: Playlist, count: Int) async throws {}
  func requestSimilarSongs(song: Song, count: Int) async throws -> [Song] { [] }
  func requestPodcastEpisodeDelete(podcastEpisode: PodcastEpisode) async throws {}
  func syncNowPlaying(song: Song, songPosition: NowPlayingSongPosition) async throws {}
  func scrobble(song: Song, date: Date?) async throws {}
  func setRating(song: Song, rating: Int) async throws {}
  func setRating(album: Album, rating: Int) async throws {}
  func setRating(artist: Artist, rating: Int) async throws {}
  func setFavorite(song: Song, isFavorite: Bool) async throws {}
  func setFavorite(album: Album, isFavorite: Bool) async throws {}
  func setFavorite(artist: Artist, isFavorite: Bool) async throws {}
  func parseLyrics(relFilePath: URL) async throws -> LyricsList { LyricsList() }
}

// MARK: - PlaylistSongAdderTest

@MainActor
class PlaylistSongAdderTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var syncer: RECORDING_PlaylistAddSyncer!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    syncer = RECORDING_PlaylistAddSyncer()
  }

  override func tearDown() {}

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  private func makePlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  /// The happy path: N songs are uploaded to the server AND appended locally.
  func testAddsNSongsUploadsThenAppends() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let s1 = makeSong(id: "t-1")
    let s2 = makeSong(id: "t-2")
    let s3 = makeSong(id: "t-3")
    library.saveContext()

    try await PlaylistSongAdder.add(songs: [s1, s2, s3], to: playlist, using: syncer)

    XCTAssertEqual(syncer.addSongsCalls.count, 1, "exactly one upload for the batch")
    XCTAssertEqual(syncer.addSongsCalls.first?.playlistId, "pl-1")
    XCTAssertEqual(syncer.addSongsCalls.first?.songIds, ["t-1", "t-2", "t-3"])
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1", "t-2", "t-3"], "appended locally in order")
  }

  /// An empty batch is a no-op: no upload, no local change.
  func testEmptyBatchIsNoOp() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    library.saveContext()

    try await PlaylistSongAdder.add(songs: [], to: playlist, using: syncer)

    XCTAssertTrue(syncer.addSongsCalls.isEmpty)
    XCTAssertTrue(playlist.playables.isEmpty)
  }

  /// On a sync failure the upload throws and the local append MUST NOT run —
  /// we never show songs in a playlist the server rejected.
  func testSyncFailureAbortsLocalAppend() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let s1 = makeSong(id: "t-1")
    library.saveContext()

    struct UploadFailed: Error {}
    syncer.uploadError = UploadFailed()

    do {
      try await PlaylistSongAdder.add(songs: [s1], to: playlist, using: syncer)
      XCTFail("expected the upload error to propagate")
    } catch is UploadFailed {
      // expected
    }

    XCTAssertTrue(
      playlist.playables.isEmpty,
      "local append must not run when the server upload fails"
    )
  }

  /// Adding into a playlist that already holds items appends after them.
  func testAppendsAfterExistingItems() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let existing = makeSong(id: "t-existing")
    playlist.append(playable: existing)
    let s1 = makeSong(id: "t-1")
    library.saveContext()

    try await PlaylistSongAdder.add(songs: [s1], to: playlist, using: syncer)

    XCTAssertEqual(playlist.playables.map(\.id), ["t-existing", "t-1"])
  }
}
