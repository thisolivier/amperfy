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

  /// Regression for the confirmed root cause: a playlist that was marked synced
  /// but whose local items are stale/empty (because it was edited on the server
  /// after sync) silently contributes nothing to the reverse membership lookup.
  /// After a count-mismatch re-sync repopulates its items, membership is complete.
  func testStalePlaylistReturnsCompleteMembershipAfterResync() {
    let song = makeSong(id: "pmq-song-resync")
    let playlist = makePlaylist(id: "pmq-pl-stale", name: "Edited On Server")
    // Server reports the playlist now has this song, but locally its items are
    // empty (stale after a server-side edit). Simulate the tracker having marked
    // it synced during an earlier, now-outdated sync.
    playlist.remoteSongCount = 1
    library.saveContext()

    let tracker = PlaylistItemsSyncTracker(defaults: makeIsolatedDefaults())
    tracker.markSynced(playlist.id)

    // Before any re-sync, membership is EMPTY — the exact user-visible bug.
    let staleResults = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-resync",
      in: testContext
    )
    XCTAssertTrue(
      staleResults.isEmpty,
      "Baseline: stale/empty local items make the reverse lookup miss the song"
    )

    // Reconcile detects the count mismatch (local 0 vs remote 1) and invalidates.
    let didInvalidate = tracker.reconcile(
      playlistId: playlist.id,
      localItemCount: playlist.localItemCount,
      remoteSongCount: playlist.remoteSongCount
    )
    XCTAssertTrue(didInvalidate, "Count mismatch must invalidate the synced flag")
    XCTAssertFalse(tracker.isSynced(playlist.id))

    // Simulate the resulting re-fetch (getPlaylist) repopulating the items.
    playlist.append(playable: song)
    library.saveContext()

    // Now the membership lookup is complete.
    let resyncedResults = PlaylistMembershipQuery.playlistsContaining(
      songId: "pmq-song-resync",
      in: testContext
    )
    XCTAssertEqual(
      resyncedResults.map { $0.id },
      ["pmq-pl-stale"],
      "After re-sync the song's playlist membership is complete"
    )
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "PlaylistMembershipQueryTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
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
