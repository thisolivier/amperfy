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

  // MARK: - sharedPlaylistCount (Related Tracks reason line)

  /// Two songs co-occurring in two user playlists yields a shared count of 2.
  func testSharedPlaylistCountCountsCoOccurrences() {
    let songA = makeSong(id: "spc-song-a")
    let songB = makeSong(id: "spc-song-b")
    let playlistOne = makePlaylist(id: "spc-pl-1", name: "Road Trip")
    let playlistTwo = makePlaylist(id: "spc-pl-2", name: "Sunday Chill")
    playlistOne.append(playable: songA)
    playlistOne.append(playable: songB)
    playlistTwo.append(playable: songA)
    playlistTwo.append(playable: songB)
    library.saveContext()

    let count = PlaylistMembershipQuery.sharedPlaylistCount(
      songIdA: "spc-song-a",
      songIdB: "spc-song-b",
      in: testContext
    )
    XCTAssertEqual(count, 2, "Both songs share two playlists")
  }

  /// A playlist containing only one of the two songs does not count toward the shared total.
  func testSharedPlaylistCountIgnoresPlaylistsMissingOneSong() {
    let songA = makeSong(id: "spc2-song-a")
    let songB = makeSong(id: "spc2-song-b")
    let sharedPlaylist = makePlaylist(id: "spc2-pl-shared", name: "Both Here")
    let soloPlaylist = makePlaylist(id: "spc2-pl-solo", name: "Only A")
    sharedPlaylist.append(playable: songA)
    sharedPlaylist.append(playable: songB)
    soloPlaylist.append(playable: songA)
    library.saveContext()

    let count = PlaylistMembershipQuery.sharedPlaylistCount(
      songIdA: "spc2-song-a",
      songIdB: "spc2-song-b",
      in: testContext
    )
    XCTAssertEqual(count, 1, "Only the playlist holding both songs counts")
  }

  /// The reason-line drift bug: once a song is removed from the only shared
  /// playlist, the live shared count must be zero (no "in N playlists" claim).
  func testSharedPlaylistCountReflectsLiveRemoval() {
    let songA = makeSong(id: "spc3-song-a")
    let songB = makeSong(id: "spc3-song-b")
    let playlist = makePlaylist(id: "spc3-pl", name: "Ephemeral")
    playlist.append(playable: songA)
    playlist.append(playable: songB)
    library.saveContext()

    XCTAssertEqual(
      PlaylistMembershipQuery.sharedPlaylistCount(
        songIdA: "spc3-song-a", songIdB: "spc3-song-b", in: testContext
      ),
      1,
      "Both songs share the playlist before removal"
    )

    playlist.remove(at: playlist.playables.firstIndex(where: { $0.id == "spc3-song-b" })!)
    library.saveContext()

    XCTAssertEqual(
      PlaylistMembershipQuery.sharedPlaylistCount(
        songIdA: "spc3-song-a", songIdB: "spc3-song-b", in: testContext
      ),
      0,
      "After removing song B live, the shared count must drop to zero — no stale reason"
    )
  }

  /// Smart playlists are excluded from the shared count (mirrors playlistsContaining).
  func testSharedPlaylistCountExcludesSmartPlaylists() {
    let songA = makeSong(id: "spc4-song-a")
    let songB = makeSong(id: "spc4-song-b")
    let smartPlaylist = makePlaylist(
      id: "\(Playlist.smartPlaylistIdPrefix)auto",
      name: "Auto Mix"
    )
    smartPlaylist.append(playable: songA)
    smartPlaylist.append(playable: songB)
    library.saveContext()

    let count = PlaylistMembershipQuery.sharedPlaylistCount(
      songIdA: "spc4-song-a",
      songIdB: "spc4-song-b",
      in: testContext
    )
    XCTAssertEqual(count, 0, "Smart playlists must not contribute to the shared count")
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
