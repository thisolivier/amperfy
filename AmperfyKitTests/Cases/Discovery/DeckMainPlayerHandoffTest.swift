//
//  DeckMainPlayerHandoffTest.swift
//  AmperfyKitTests
//
//  State-machine tests for the triage-A1 deck audio semantics (user-settled
//  2026-07-05): no pause on deck open; pause on first sprite play; resume on
//  close only if the deck paused it; a main player playing at close is never
//  touched.
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
final class DeckMainPlayerHandoffTest: XCTestCase {
  private var mainPlayerIsPlaying = false
  private var pauseCallCount = 0
  private var resumeCallCount = 0

  override func setUp() {
    mainPlayerIsPlaying = false
    pauseCallCount = 0
    resumeCallCount = 0
  }

  /// Pause/resume mutate `mainPlayerIsPlaying` like the real player would.
  private func makeHandoff() -> DeckMainPlayerHandoff {
    DeckMainPlayerHandoff(
      isMainPlayerPlaying: { self.mainPlayerIsPlaying },
      pauseMainPlayer: {
        self.pauseCallCount += 1
        self.mainPlayerIsPlaying = false
      },
      resumeMainPlayer: {
        self.resumeCallCount += 1
        self.mainPlayerIsPlaying = true
      }
    )
  }

  func testDeckOpenDoesNotTouchAPlayingMainPlayer() {
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    XCTAssertEqual(pauseCallCount, 0, "opening the deck must not pause")
    XCTAssertTrue(mainPlayerIsPlaying)
    XCTAssertFalse(handoff.didPauseMainPlayer)
  }

  func testFirstSpritePlayPausesPlayingMainPlayerAndRemembers() {
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    XCTAssertEqual(pauseCallCount, 1)
    XCTAssertFalse(mainPlayerIsPlaying)
    XCTAssertTrue(handoff.didPauseMainPlayer)
  }

  func testLaterSpritePlaysWhileMainPlayerStaysPausedAreNoOps() {
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    handoff.spritePlaybackDidStart()
    handoff.spritePlaybackDidStart()
    XCTAssertEqual(pauseCallCount, 1, "only the first sprite play pauses")
  }

  func testSpritePlayWithMainPlayerNotPlayingDoesNothingAndCloseDoesNotResume() {
    mainPlayerIsPlaying = false
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    XCTAssertEqual(pauseCallCount, 0)
    XCTAssertFalse(handoff.didPauseMainPlayer)
    handoff.deckWillClose()
    XCTAssertEqual(resumeCallCount, 0, "the deck never paused it, so it must not resume it")
  }

  func testCloseResumesWhenDeckPausedItAndItIsStillPaused() {
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    handoff.deckWillClose()
    XCTAssertEqual(resumeCallCount, 1)
    XCTAssertTrue(mainPlayerIsPlaying)
  }

  func testCloseNeverTouchesAMainPlayerThatIsPlaying() {
    // Deck paused it, then the user started real playback from a collection
    // detail pushed over the deck — at pop time the main player is playing.
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    mainPlayerIsPlaying = true // detail-initiated real playback
    handoff.deckWillClose()
    XCTAssertEqual(resumeCallCount, 0, "playing at close: never touch it")
    XCTAssertTrue(mainPlayerIsPlaying)
  }

  func testCloseWithoutAnySpritePlayLeavesEverythingAlone() {
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.deckWillClose()
    XCTAssertEqual(pauseCallCount, 0)
    XCTAssertEqual(resumeCallCount, 0)
  }

  func testSpriteOverDetailInitiatedPlaybackPausesAgainAndCloseResumes() {
    // Deck paused it, user played real music from a pushed detail, came back,
    // needle-dropped again: sprite start pauses the main player a second time,
    // and close resumes it (the deck was the one who paused it, again).
    mainPlayerIsPlaying = true
    let handoff = makeHandoff()
    handoff.spritePlaybackDidStart()
    mainPlayerIsPlaying = true // detail-initiated real playback
    handoff.spritePlaybackDidStart()
    XCTAssertEqual(pauseCallCount, 2, "sprite audio never plays over the main player")
    handoff.deckWillClose()
    XCTAssertEqual(resumeCallCount, 1)
  }
}
