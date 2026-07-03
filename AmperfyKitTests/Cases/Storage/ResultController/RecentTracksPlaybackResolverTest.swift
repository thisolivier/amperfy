//
//  RecentTracksPlaybackResolverTest.swift
//  AmperfyKitTests
//
//  Created by implementer-amperfy on 2026-07-02.
//  Copyright (c) 2026 Amperfy. All rights reserved.
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

/// Unit tests for `RecentTracksPlaybackResolver`.
///
/// The first two tests (`testStaleIndexResolvesToWrongSong_shiftedScenario`
/// and `testStaleIndexResolvesToWrongSong_removedScenario`) are the
/// **reproduction** — they assert against plain index-based array access
/// directly (the OLD/buggy `RecentTracksDetailVC` logic), demonstrating that
/// a reload racing a tap can make an index-based lookup resolve to the wrong
/// song. They exist to prove the bug is real, not hypothetical, and should
/// keep passing even after the fix (they document the shape of the race,
/// independent of the resolver).
///
/// The remaining tests exercise the resolver itself, proving it resolves by
/// identity rather than position and is therefore immune to the race.
@MainActor
class RecentTracksPlaybackResolverTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: - Helpers

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  // MARK: - Reproduction: the pre-fix bug is real

  /// Simulates a user tapping row 0 (showing "song-X") while `songs =
  /// [songX, songY, songZ]`, then a reload replaces `songs` with `[songW,
  /// songX, songZ]` (songX shifted from index 0 to index 1) before the tap
  /// is processed. The OLD/buggy logic re-reads `newSongs[0]` — i.e. it
  /// trusts the row index, not the tapped song's identity — and lands on
  /// the wrong song.
  func testStaleIndexResolvesToWrongSong_shiftedScenario() {
    let songX = makeSong(id: "song-X")
    let songY = makeSong(id: "song-Y")
    let songZ = makeSong(id: "song-Z")
    let songW = makeSong(id: "song-W")

    let songsAtTouchTime = [songX, songY, songZ]
    let tappedRowIndex = 0
    XCTAssertEqual(songsAtTouchTime[tappedRowIndex].id, "song-X")

    // Reload races the tap: songX shifts from index 0 to index 1.
    let songsAtTapProcessedTime = [songW, songX, songZ]

    // OLD/buggy behaviour: index-based lookup against the NEW array.
    let buggyResolvedSong = songsAtTapProcessedTime[tappedRowIndex]
    XCTAssertNotEqual(
      buggyResolvedSong.id,
      "song-X",
      "index-based lookup should (incorrectly) resolve to the song that now "
        + "occupies the tapped row, not the song the user actually tapped"
    )
    XCTAssertEqual(buggyResolvedSong.id, "song-W")
  }

  /// Same race, but the reload drops the tapped song from the list
  /// entirely. The OLD/buggy index-based logic still faithfully returns
  /// whatever now sits at that index — some other, unrelated song — rather
  /// than recognising the tapped song is gone.
  func testStaleIndexResolvesToWrongSong_removedScenario() {
    let songX = makeSong(id: "song-X")
    let songY = makeSong(id: "song-Y")
    let songZ = makeSong(id: "song-Z")
    let songW = makeSong(id: "song-W")

    let songsAtTouchTime = [songX, songY, songZ]
    let tappedRowIndex = 0
    XCTAssertEqual(songsAtTouchTime[tappedRowIndex].id, "song-X")

    // Reload races the tap: songX is removed entirely.
    let songsAtTapProcessedTime = [songW, songY, songZ]

    let buggyResolvedSong = songsAtTapProcessedTime[tappedRowIndex]
    XCTAssertNotEqual(
      buggyResolvedSong.id,
      "song-X",
      "the tapped song is gone, yet index-based lookup silently plays "
        + "whatever else now occupies that row"
    )
    XCTAssertEqual(buggyResolvedSong.id, "song-W")
  }

  // MARK: - Resolver correctness

  /// When a reload shifts the tapped song to a new index, the resolver
  /// still finds it by id and starts playback at its NEW correct position.
  func testResolverFindsShiftedSongAtItsNewIndex() {
    let songX = makeSong(id: "song-X")
    let songZ = makeSong(id: "song-Z")
    let songW = makeSong(id: "song-W")

    let currentSongs = [songW, songX, songZ]
    let result = RecentTracksPlaybackResolver.resolvePlayContext(
      tappedSongId: "song-X",
      name: "Recently Added Tracks",
      currentSongs: currentSongs
    )

    let unwrappedResult = try! XCTUnwrap(result)
    XCTAssertEqual(unwrappedResult.index, 1)
    XCTAssertEqual((unwrappedResult.playables[unwrappedResult.index] as? Song)?.id, "song-X")
  }

  /// When a reload drops the tapped song from the list, the resolver
  /// returns `nil` — a graceful no-op, never a crash and never playback of
  /// some other, unrelated song.
  func testResolverReturnsNilWhenTappedSongWasRemoved() {
    let songY = makeSong(id: "song-Y")
    let songZ = makeSong(id: "song-Z")
    let songW = makeSong(id: "song-W")

    let currentSongs = [songW, songY, songZ]
    let result = RecentTracksPlaybackResolver.resolvePlayContext(
      tappedSongId: "song-X",
      name: "Recently Added Tracks",
      currentSongs: currentSongs
    )

    XCTAssertNil(result)
  }

  /// Baseline sanity check: when no reload happened, the resolver agrees
  /// with the naive index-based approach — the fix does not change
  /// behaviour in the common, non-racy case.
  func testResolverMatchesNaiveIndexApproachWhenNoReloadHappened() {
    let songX = makeSong(id: "song-X")
    let songY = makeSong(id: "song-Y")
    let songZ = makeSong(id: "song-Z")

    let currentSongs = [songX, songY, songZ]
    let tappedRowIndex = 0
    let tappedSong = currentSongs[tappedRowIndex]

    let result = RecentTracksPlaybackResolver.resolvePlayContext(
      tappedSongId: tappedSong.id,
      name: "Recently Added Tracks",
      currentSongs: currentSongs
    )

    let unwrappedResult = try! XCTUnwrap(result)
    XCTAssertEqual(unwrappedResult.index, tappedRowIndex)
    XCTAssertEqual(
      (unwrappedResult.playables[unwrappedResult.index] as? Song)?.id,
      currentSongs[tappedRowIndex].id
    )
  }
}
