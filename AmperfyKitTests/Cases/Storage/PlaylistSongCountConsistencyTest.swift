//
//  PlaylistSongCountConsistencyTest.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — the detail header's song count lagging one save behind.
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

/// `Playlist.songCount` is a denormalised cache of `items.count`, and this pins
/// the rule that it may never disagree with the rows **at the moment anything
/// is told the playlist changed**.
///
/// Why that exact moment: the detail header is refreshed from
/// `snapshotDidChange`, which the fetched-results controller drives off
/// `objectsDidChange` — and `objectsDidChange` is posted by
/// `processPendingChanges` at the START of `save()`, whereas `songCount` was
/// only recomputed later in the same save by `PlaylistMO.willSave()`. So every
/// reader woken by a change read the count as it was BEFORE that change.
///
/// `duration` never had the bug because it is mutated eagerly in the mutator,
/// before the save. That asymmetry is what made the symptom so odd: after
/// rolling back a 2-song refused add from a 6-song playlist the header settled
/// on "5 Songs · 15m" — the duration already final, the count exactly one save
/// behind.
@MainActor
final class PlaylistSongCountConsistencyTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var context: NSManagedObjectContext!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    context = library.createPlaylist(account: account).managedObject.managedObjectContext
    library.saveContext()
  }

  private func makeSong(id: String, duration: Int = 60) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    song.remoteDuration = duration
    return song
  }

  private func makePlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  /// What the header would read, sampled at every change notification that
  /// fires while `mutation` runs.
  private func sampleHeaderValuesOnEveryChangeNotification(
    for playlist: Playlist,
    whileRunning mutation: () -> ()
  )
    -> [(songCount: Int, rowCount: Int)] {
    var samples = [(songCount: Int, rowCount: Int)]()
    // `objectsDidChange` is posted synchronously, on this thread, from inside
    // `save()` — which is the whole point of the test — so reading the playlist
    // in the observer stays on the main actor despite the non-Sendable capture.
    nonisolated(unsafe) let playlistUnderObservation = playlist
    let observer = NotificationCenter.default.addObserver(
      forName: .NSManagedObjectContextObjectsDidChange,
      object: context,
      queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        samples.append((
          songCount: playlistUnderObservation.songCount,
          rowCount: playlistUnderObservation.playables.count
        ))
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    mutation()
    return samples
  }

  /// The reported repro: roll back a 2-song add from a 6-song playlist. Every
  /// notification must show a count that matches the rows at that instant —
  /// never the previous save's.
  func testCountMatchesRowsAtEveryChangeNotificationDuringARollback() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let keptSongs = (1 ... 4).map { makeSong(id: "t-kept-\($0)") }
    let addedSongs = (1 ... 2).map { makeSong(id: "t-added-\($0)") }
    library.saveContext()
    playlist.append(playables: keptSongs)
    playlist.append(playables: addedSongs)
    XCTAssertEqual(playlist.songCount, 6)

    let samples = sampleHeaderValuesOnEveryChangeNotification(for: playlist) {
      for song in addedSongs {
        playlist.remove(firstOccurrenceOfPlayable: song)
      }
    }

    XCTAssertFalse(samples.isEmpty, "the rollback must announce its changes")
    for (sampleIndex, sample) in samples.enumerated() {
      XCTAssertEqual(
        sample.songCount,
        sample.rowCount,
        """
        notification \(sampleIndex): the header would render \(
          sample
            .songCount
        ) songs while the list shows \(sample.rowCount) rows
        """
      )
    }
    XCTAssertEqual(playlist.songCount, 4, "and it ends on the truth")
    XCTAssertEqual(playlist.playables.count, 4)
  }

  /// Same guarantee on the way up, so an add can never render short either.
  func testCountMatchesRowsAtEveryChangeNotificationDuringAnAppend() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = (1 ... 3).map { makeSong(id: "t-\($0)") }
    library.saveContext()

    let samples = sampleHeaderValuesOnEveryChangeNotification(for: playlist) {
      playlist.append(playables: songs)
    }

    XCTAssertFalse(samples.isEmpty)
    for (sampleIndex, sample) in samples.enumerated() {
      XCTAssertEqual(sample.songCount, sample.rowCount, "notification \(sampleIndex)")
    }
    XCTAssertEqual(playlist.songCount, 3)
  }

  /// And when the playlist is emptied outright.
  func testCountMatchesRowsWhenAllItemsAreRemoved() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = (1 ... 3).map { makeSong(id: "t-\($0)") }
    library.saveContext()
    playlist.append(playables: songs)

    let samples = sampleHeaderValuesOnEveryChangeNotification(for: playlist) {
      playlist.removeAllItems()
    }

    for (sampleIndex, sample) in samples.enumerated() {
      XCTAssertEqual(sample.songCount, sample.rowCount, "notification \(sampleIndex)")
    }
    XCTAssertEqual(playlist.playables.count, 0)
  }

  /// The batch rollback is ONE save, so the list and header are repainted once
  /// at the final state instead of walked down through every intermediate
  /// count — and a rollback interrupted part-way cannot leave phantom songs
  /// behind (the queue rows are already resolved by the time it runs).
  func testBatchRemoveIsASingleSaveAtTheFinalState() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let keptSongs = (1 ... 4).map { makeSong(id: "t-kept-\($0)") }
    let addedSongs = (1 ... 2).map { makeSong(id: "t-added-\($0)") }
    library.saveContext()
    playlist.append(playables: keptSongs)
    playlist.append(playables: addedSongs)
    let durationWithSixSongs = playlist.duration

    let samples = sampleHeaderValuesOnEveryChangeNotification(for: playlist) {
      playlist.remove(firstOccurrencesOfPlayables: addedSongs)
    }

    XCTAssertTrue(
      samples.allSatisfy { $0.songCount == 4 && $0.rowCount == 4 },
      "every notification reports the settled state, never 5; got \(samples)"
    )
    XCTAssertEqual(playlist.playables.map(\.id), keptSongs.map(\.id))
    XCTAssertEqual(playlist.duration, durationWithSixSongs - 120, "both durations came off")
  }

  /// A deliberate duplicate add puts two copies in; rolling it back has to take
  /// out both, not the same position twice.
  func testBatchRemoveTakesOutEachDuplicateCopy() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let keptSong = makeSong(id: "t-kept")
    let duplicatedSong = makeSong(id: "t-dupe")
    library.saveContext()
    playlist.append(playables: [keptSong, duplicatedSong, duplicatedSong])
    XCTAssertEqual(playlist.songCount, 3)

    playlist.remove(firstOccurrencesOfPlayables: [duplicatedSong, duplicatedSong])

    XCTAssertEqual(playlist.playables.map(\.id), ["t-kept"], "both copies removed")
    XCTAssertEqual(playlist.songCount, 1)
  }

  /// Rolling back a song the playlist no longer holds is a no-op, not a crash
  /// or an off-by-one on something else.
  func testBatchRemoveIgnoresPlayablesThatAreNotPresent() throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let presentSong = makeSong(id: "t-present")
    let absentSong = makeSong(id: "t-absent")
    library.saveContext()
    playlist.append(playable: presentSong)

    playlist.remove(firstOccurrencesOfPlayables: [absentSong])

    XCTAssertEqual(playlist.playables.map(\.id), ["t-present"])
    XCTAssertEqual(playlist.songCount, 1)
  }

  /// The fallback must survive all this: a playlist whose items have not been
  /// fetched yet still reports the server's count, so a synced-but-unfetched
  /// playlist does not render "0 Songs" in a list.
  func testUnfetchedPlaylistStillReportsTheRemoteCount() throws {
    let playlist = makePlaylist(id: "pl-remote", name: "Not Fetched Yet")
    playlist.remoteSongCount = 25
    library.saveContext()

    XCTAssertTrue(playlist.playables.isEmpty)
    XCTAssertEqual(
      playlist.songCount,
      25,
      "with no local items the remote count is the only thing worth showing"
    )
  }
}
