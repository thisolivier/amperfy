//
//  PlaylistMembershipQueryTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (Feature C — Show playlists).
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

/// Unit tests for `PlaylistMembershipQuery` (Feature C — "In Playlists").
/// Verifies the Core Data predicate returns the correct set of playlists
/// containing a given song, excluding smart playlists and sorting by name.
@MainActor
class PlaylistMembershipQueryTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Helpers

  @discardableResult
  private func makePlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  // MARK: - Tests

  /// Song in two user playlists returns both, sorted alphabetically by name.
  func testSongInTwoPlaylistsReturnsBothSorted() {
    let song = makeSong(id: "pmq-song-1")
    let playlistBeta = makePlaylist(id: "pmq-pl-beta", name: "Beta Mix")
    let playlistAlpha = makePlaylist(id: "pmq-pl-alpha", name: "Alpha Vibes")
    playlistBeta.append(playable: song)
    playlistAlpha.append(playable: song)
    library.saveContext()

    let results = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-1",
      in: testContext
    )
    let resultIds = results.map { $0.id }
    XCTAssertEqual(
      resultIds,
      ["pmq-pl-alpha", "pmq-pl-beta"],
      "Results should be sorted by name ascending: Alpha before Beta"
    )
  }

  /// Song in zero playlists returns an empty array.
  func testSongInNoPlaylistsReturnsEmpty() {
    _ = makeSong(id: "pmq-song-lonely")
    _ = makePlaylist(id: "pmq-pl-empty", name: "Empty Playlist")
    library.saveContext()

    let results = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-lonely",
      in: testContext
    )
    XCTAssertTrue(results.isEmpty, "Song not in any playlist should return empty")
  }

  /// Song in one smart playlist and one user playlist returns only the user one.
  func testSmartPlaylistExcluded() {
    let song = makeSong(id: "pmq-song-mixed")
    let userPlaylist = makePlaylist(id: "pmq-pl-user", name: "My Favourites")
    let smartPlaylist = makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto-generated",
      name: "Auto Mix"
    )
    userPlaylist.append(playable: song)
    smartPlaylist.append(playable: song)
    library.saveContext()

    let results = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-mixed",
      in: testContext
    )
    let resultIds = results.map { $0.id }
    XCTAssertEqual(
      resultIds,
      ["pmq-pl-user"],
      "Smart playlists should be excluded from membership results"
    )
  }

  /// Playlists with empty or nil names are excluded from results.
  func testEmptyNamePlaylistExcluded() {
    let song = makeSong(id: "pmq-song-named")
    let namedPlaylist = makePlaylist(id: "pmq-pl-named", name: "Real Playlist")
    let emptyNamePlaylist = makePlaylist(id: "pmq-pl-empty-name", name: "")
    namedPlaylist.append(playable: song)
    emptyNamePlaylist.append(playable: song)
    library.saveContext()

    let results = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-named",
      in: testContext
    )
    let resultIds = results.map { $0.id }
    XCTAssertEqual(
      resultIds,
      ["pmq-pl-named"],
      "Playlists with empty names should be excluded"
    )
  }
}
