//
//  PlaylistAddSyncerTestDouble.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — playlist song adds became a durable, retried queue.
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
import Foundation

// MARK: - RECORDING_PlaylistAddSyncer

/// A `LibrarySyncer` that records the two calls AMP-28 cares about —
/// `syncUpload(playlistToAddSongs:songs:)` and `syncDown(playlist:)` — in the
/// order they happen, and can be told to throw a chosen error from the upload.
///
/// The recorded *order* is the point. Route 2's bug was that it uploaded before
/// appending locally, so the regression test needs to know what the library
/// looked like at the moment the upload was attempted — hence
/// `onSyncUpload`, which the test uses to snapshot local state mid-flight.
///
/// Built locally per the house "define the mock in the test that needs it"
/// convention (the shared `SPY_LibrarySyncer` only records album syncs).
@MainActor
final class RECORDING_PlaylistAddSyncer: LibrarySyncer {
  enum RecordedCall: Equatable {
    case upload(playlistName: String, songIds: [String])
    case syncDown(playlistName: String)
  }

  private(set) var recordedCalls = [RecordedCall]()

  /// Thrown from the next `syncUpload(playlistToAddSongs:)`. Pop-style: it is
  /// consumed per call from the front of this list, so a test can make the
  /// first attempt fail and the retry succeed. An empty list means success.
  var uploadErrorsToThrow = [Error]()

  /// Invoked at the top of `syncUpload(playlistToAddSongs:)`, before success or
  /// failure is decided. Lets a test assert what the local library already held
  /// at upload time.
  var onSyncUpload: ((Playlist, [Song]) -> ())?

  /// Invoked inside `syncDown(playlist:)`. Used to simulate the server-wins
  /// positional rewrite that truncates local-only tail items.
  var onSyncDown: ((Playlist) -> ())?

  var uploadCallCount: Int {
    recordedCalls.filter {
      if case .upload = $0 { return true } else { return false }
    }.count
  }

  var syncDownCallCount: Int {
    recordedCalls.filter {
      if case .syncDown = $0 { return true } else { return false }
    }.count
  }

  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws {
    onSyncUpload?(playlist, songs)
    recordedCalls.append(.upload(playlistName: playlist.name, songIds: songs.map(\.id)))
    if !uploadErrorsToThrow.isEmpty {
      throw uploadErrorsToThrow.removeFirst()
    }
  }

  func syncDown(playlist: Playlist) async throws {
    recordedCalls.append(.syncDown(playlistName: playlist.name))
    onSyncDown?(playlist)
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

// MARK: - PlaylistAddTestErrors

/// The error shapes the upload worker has to tell apart.
enum PlaylistAddTestErrors {
  /// Subsonic error 50 — "not authorized for the given operation". The refusal
  /// the Navidrome fork returns for a playlist it considers server-owned, and
  /// the one that must roll the local append back.
  static func subsonicNotAuthorized(message: String = "") -> ResponseError {
    ResponseError(
      type: .api,
      statusCode: SubsonicServerApi.SubsonicError.userIsNotAuthorized.rawValue,
      message: message
    )
  }

  /// Subsonic error 70 — the server no longer has this playlist.
  static func subsonicDataNotFound(message: String = "") -> ResponseError {
    ResponseError(
      type: .api,
      statusCode: SubsonicServerApi.SubsonicError.requestedDataNotFound.rawValue,
      message: message
    )
  }

  /// A 5xx. Retryable: the server is unwell, not refusing.
  static func serverSideHttpFailure() -> ResponseError {
    ResponseError(type: .api, statusCode: 503, message: "HTTP 503")
  }

  /// A dropped connection. Retryable.
  static func networkTimeout() -> Error {
    URLError(.timedOut)
  }
}
