import AmperfyKit
import Combine
import UIKit

// MARK: - AuditionDeckAudioCoordinator

/// Owns everything audio-behavior-shaped from design §6, updated for Deck v2:
/// - Main-player pause/resume handoff (pause on deck open if it was playing, resume when the
///   deck page POPS — there is no in-deck Play anymore, so no handoff-to-main-player case).
/// - The single-active-`NeedleDropSpritePlayer`-at-a-time invariant across cards.
/// - Stopping sprite audio synchronously on card swipe, page pop, a detail pushed over the deck
///   (`AuditionDeckHostVC.viewWillDisappear`), and app-background.
///
/// One instance is owned per deck session by `AuditionDeckController`. Deck v2 removed audition
/// tracking (user-settled 2026-07-03): there is no first-audition callback and no per-candidate
/// audition bookkeeping here.
@MainActor
final class AuditionDeckAudioCoordinator {
  private let player: PlayerFacade
  private let wasPlayingOnOpen: Bool

  private var spritePlayers: [String: NeedleDropSpritePlayer] = [:]
  /// `nonisolated(unsafe)`: only read/written from `init`/`deinit` (never concurrently), and
  /// `deinit` on an `@MainActor` class is itself `nonisolated` by default in Swift 6 — matches the
  /// same accommodation already used elsewhere in this codebase (e.g.
  /// `AmperfyKit/Player/NeedleDrop/NeedleDropSpritePlayer.swift`) for state that's provably
  /// single-threaded in practice but not statically Sendable.
  nonisolated(unsafe) private var backgroundObserverToken: NSObjectProtocol?

  init(player: PlayerFacade) {
    self.player = player
    self.wasPlayingOnOpen = player.isPlaying
    if wasPlayingOnOpen {
      player.pause()
    }
    // `willResignActiveNotification` (not `didEnterBackgroundNotification`) so audio actually
    // stops the instant the app loses focus (e.g. Control Center, incoming call), not only once
    // fully backgrounded.
    self.backgroundObserverToken = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.stopAllSpritePlayers()
      }
    }
  }

  deinit {
    if let backgroundObserverToken {
      NotificationCenter.default.removeObserver(backgroundObserverToken)
    }
  }

  /// Returns the single sprite player owned for `candidateId`, creating it on first use. Reused
  /// across relayouts of the same card so paused/riding state survives scroll-position churn
  /// within the prefetch window.
  func spritePlayer(
    for candidateId: String,
    manifest: NeedleDropManifest
  )
    -> NeedleDropSpritePlayer {
    if let existing = spritePlayers[candidateId] { return existing }
    let newPlayer = NeedleDropSpritePlayer(spriteURL: manifest.spriteURL)
    spritePlayers[candidateId] = newPlayer
    return newPlayer
  }

  /// Card left the prefetch window (scrolled far away) — stop and release its player. Never
  /// releases the currently-current card even if asked, to avoid killing audio mid-transition.
  func releaseSpritePlayer(for candidateId: String, currentCandidateId: String?) {
    guard candidateId != currentCandidateId else { return }
    spritePlayers[candidateId]?.stop()
    spritePlayers.removeValue(forKey: candidateId)
  }

  /// Stops every sprite player except (optionally) one — the single-active-player invariant.
  /// Called on: new current card (keep the new one), detail pushed over the deck, page pop,
  /// app background.
  func stopAllSpritePlayers(except keepCandidateId: String? = nil) {
    for (candidateId, spritePlayer) in spritePlayers where candidateId != keepCandidateId {
      spritePlayer.stop()
    }
  }

  /// Call once, when the deck page pops off the navigation stack (back button or end-card Done)
  /// — stops all sprite audio and resumes the main player if it was playing when the deck opened.
  /// Calling `play()` when the main player is already playing (e.g. the user started real
  /// playback from a detail screen pushed over the deck) is a no-op.
  func deckWillClose() {
    stopAllSpritePlayers()
    if wasPlayingOnOpen {
      player.play()
    }
  }
}
