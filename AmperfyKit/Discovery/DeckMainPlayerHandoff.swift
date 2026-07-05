//
//  DeckMainPlayerHandoff.swift
//  AmperfyKit
//
//  The Audition Deck's main-player pause/resume state machine, extracted from
//  the app target's AuditionDeckAudioCoordinator so the semantics are
//  unit-testable (AmperfyKitTests has no Amperfy-app-target visibility — same
//  reasoning as DeckDealingGate).
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

import Foundation

// MARK: - DeckMainPlayerHandoff

/// Triage 2026-07-05 A1 semantics (user-settled):
/// - Opening the deck leaves the main player alone — no pause-on-open.
/// - The first time sprite audio actually starts (needle-drop touch; there is
///   no auto-play), pause the main player if it is playing and remember that
///   this deck session did so.
/// - On deck close (page pop), resume ONLY if this session paused it AND it is
///   still paused at close time. If the main player is PLAYING at close (e.g.
///   the user started real playback from a collection detail pushed over the
///   deck), never touch it.
///
/// The three closures abstract `PlayerFacade` down to exactly what this state
/// machine needs, so tests exercise it without a full player mock.
@MainActor
public final class DeckMainPlayerHandoff {
  private let isMainPlayerPlaying: () -> Bool
  private let pauseMainPlayer: () -> ()
  private let resumeMainPlayer: () -> ()

  /// True once this deck session paused the main player because sprite audio
  /// started over it.
  public private(set) var didPauseMainPlayer = false

  public init(
    isMainPlayerPlaying: @escaping () -> Bool,
    pauseMainPlayer: @escaping () -> (),
    resumeMainPlayer: @escaping () -> ()
  ) {
    self.isMainPlayerPlaying = isMainPlayerPlaying
    self.pauseMainPlayer = pauseMainPlayer
    self.resumeMainPlayer = resumeMainPlayer
  }

  /// Call whenever a sprite player reports it actually started producing
  /// audio. Pauses the main player only when it is playing at that moment —
  /// so the first sprite play pauses it, later sprite plays are no-ops while
  /// it stays paused, and if real playback restarted meanwhile (detail screen
  /// pushed over the deck) a fresh sprite play pauses it again rather than
  /// letting sprite audio run over it.
  public func spritePlaybackDidStart() {
    guard isMainPlayerPlaying() else { return }
    pauseMainPlayer()
    didPauseMainPlayer = true
  }

  /// Call once, when the deck page pops. Resumes the main player only if this
  /// session paused it and nothing else has started it since — a main player
  /// that is playing at close time is never touched.
  public func deckWillClose() {
    guard !isMainPlayerPlaying() else { return }
    guard didPauseMainPlayer else { return }
    resumeMainPlayer()
  }
}
