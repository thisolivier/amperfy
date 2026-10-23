//
//  PendingPlaylistSongAddReconcilerTest.swift
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
import XCTest

@MainActor
final class PendingPlaylistSongAddReconcilerTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PendingPlaylistSongAddStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PendingPlaylistSongAddStore(library: library)
  }

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

  /// Stand in for what `SsPlaylistSongsParserDelegate` does: rewrite the
  /// playlist's items from the server envelope, deleting anything the server
  /// did not mention. For a pending add that is precisely wrong — hence the
  /// guard.
  private func simulateServerWinsRewrite(of playlist: Playlist, toServerSongs serverSongs: [Song]) {
    playlist.removeAllItems()
    playlist.append(playables: serverSongs)
  }

  // MARK: - The core guard

  /// The AMP-28 loss, reproduced and then prevented: a fetch truncates the
  /// local tail, and the guard puts the still-queued song back.
  func testReappliesASongTheFetchTruncated() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let serverSong = makeSong(id: "t-server")
    let pendingSong = makeSong(id: "t-pending")
    library.saveContext()

    playlist.append(playables: [serverSong, pendingSong])
    store.enqueue(songs: [pendingSong], to: playlist, account: account)

    // The server has not been told about t-pending yet, so its envelope omits it.
    simulateServerWinsRewrite(of: playlist, toServerSongs: [serverSong])
    XCTAssertEqual(playlist.playables.map(\.id), ["t-server"], "the fetch truncated the add")

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: playlist,
      store: store
    )

    XCTAssertEqual(restoredCount, 1)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-server", "t-pending"])
    XCTAssertEqual(
      store.pendingAddCount(for: account),
      1,
      "restoring the item does not resolve the add — it is still owed to the server"
    )
  }

  /// Several queued songs come back in the order they were tapped.
  func testReappliesEveryTruncatedSongInTapOrder() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let serverSong = makeSong(id: "t-server")
    let pendingSongs = (1 ... 3).map { makeSong(id: "t-pending-\($0)") }
    library.saveContext()

    playlist.append(playables: [serverSong] + pendingSongs)
    store.enqueue(songs: pendingSongs, to: playlist, account: account)
    simulateServerWinsRewrite(of: playlist, toServerSongs: [serverSong])

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: playlist,
      store: store
    )

    XCTAssertEqual(restoredCount, 3)
    XCTAssertEqual(
      playlist.playables.map(\.id),
      ["t-server", "t-pending-1", "t-pending-2", "t-pending-3"]
    )
  }

  // MARK: - When the guard must do nothing

  /// Once the upload has landed the rows are gone, so the guard leaves the
  /// server's own copy of the playlist entirely alone. This is what keeps a
  /// successful add from being doubled by its own reconciling fetch.
  func testDoesNothingWhenNothingIsQueued() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: playlist,
      store: store
    )

    XCTAssertEqual(restoredCount, 0)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1", "t-2"])
  }

  /// A queued song the fetch *did* return is already present, so it is not
  /// appended a second time. Presence, not multiplicity: the alternative would
  /// double every add whose upload actually succeeded while we believed it had
  /// not — strictly worse than losing a deliberate duplicate.
  func testDoesNotDuplicateAQueuedSongTheFetchKept() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)

    // The upload had in fact landed, so the envelope includes the song.
    simulateServerWinsRewrite(of: playlist, toServerSongs: [song])

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: playlist,
      store: store
    )

    XCTAssertEqual(restoredCount, 0)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"], "no second copy")
  }

  /// Another playlist's queued work must not leak into this one.
  func testIgnoresPendingAddsForOtherPlaylists() throws {
    let fetchedPlaylist = makePlaylist(id: "pl-1", name: "Fetched")
    let otherPlaylist = makePlaylist(id: "pl-2", name: "Other")
    let otherSong = makeSong(id: "t-other")
    library.saveContext()
    store.enqueue(songs: [otherSong], to: otherPlaylist, account: account)

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: fetchedPlaylist,
      store: store
    )

    XCTAssertEqual(restoredCount, 0)
    XCTAssertTrue(fetchedPlaylist.playables.isEmpty)
  }

  /// A fetch that empties the playlist entirely still gets the queued adds
  /// back — the guard does not depend on anything surviving the rewrite.
  func testReappliesWhenTheFetchEmptiedThePlaylist() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)

    simulateServerWinsRewrite(of: playlist, toServerSongs: [])
    XCTAssertTrue(playlist.playables.isEmpty)

    let restoredCount = PendingPlaylistSongAddReconciler.reapplyPendingAdds(
      to: playlist,
      store: store
    )

    XCTAssertEqual(restoredCount, 1)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"])
  }
}
