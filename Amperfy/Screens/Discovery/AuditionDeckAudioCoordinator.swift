import AmperfyKit
import Combine
import UIKit

// MARK: - AuditionDeckAudioCoordinator

/// Owns everything audio-behavior-shaped from design §6:
/// - Main-player pause/resume handoff (pause on deck open if it was playing, resume on close
///   unless the user tapped Play in the deck).
/// - The single-active-`NeedleDropSpritePlayer`-at-a-time invariant across cards.
/// - Stopping sprite audio synchronously on card swipe, Play, close, and app-background.
///
/// One instance is owned per deck session by `AuditionDeckController`.
@MainActor
final class AuditionDeckAudioCoordinator {
  /// Fired the first time a given card's sprite player starts audibly playing this session — the
  /// controller uses this to drive the end card's "auditioned <n>" counter (design §5.5:
  /// "cards whose sprite ever played").
  var onFirstAudition: ((String) -> ())?

  private let player: PlayerFacade
  private let wasPlayingOnOpen: Bool
  private var didHandOffToMainPlayer = false

  private var spritePlayers: [String: NeedleDropSpritePlayer] = [:]
  private var spriteSubscriptions: [String: AnyCancellable] = [:]
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
    // No existing precedent for a background-transition NotificationCenter observer was found
    // anywhere in Amperfy/AmperfyKit at the time this was written (checked both targets) — this
    // is a fresh addition, not a reuse of an established pattern. `willResignActiveNotification`
    // (not `didEnterBackgroundNotification`) so audio actually stops the instant the app loses
    // focus (e.g. Control Center, incoming call), not only once fully backgrounded.
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
    spriteSubscriptions[candidateId] = newPlayer.$isPlaying
      .filter { $0 }
      .first()
      .sink { [weak self] _ in self?.onFirstAudition?(candidateId) }
    return newPlayer
  }

  /// Card left the prefetch window (scrolled far away) — stop and release its player. Never
  /// releases the currently-current card even if asked, to avoid killing audio mid-transition.
  func releaseSpritePlayer(for candidateId: String, currentCandidateId: String?) {
    guard candidateId != currentCandidateId else { return }
    spritePlayers[candidateId]?.stop()
    spritePlayers.removeValue(forKey: candidateId)
    spriteSubscriptions.removeValue(forKey: candidateId)
  }

  /// Stops every sprite player except (optionally) one — the single-active-player invariant.
  /// Called on: new current card (keep the new one), Play tapped, deck close, app background.
  func stopAllSpritePlayers(except keepCandidateId: String? = nil) {
    for (candidateId, spritePlayer) in spritePlayers where candidateId != keepCandidateId {
      spritePlayer.stop()
    }
  }

  /// Marks that the user tapped Play in the deck: the main player queue now owns playback, so
  /// `deckWillClose()` must NOT also resume whatever was playing before the deck opened.
  func markPlayHandedOffToMainPlayer() {
    didHandOffToMainPlayer = true
  }

  /// Call once, right before dismissing the deck (X, Play, or end-card Done) — stops all sprite
  /// audio and resumes the main player if it was playing on open and the user didn't hand off via
  /// Play.
  func deckWillClose() {
    stopAllSpritePlayers()
    if wasPlayingOnOpen, !didHandOffToMainPlayer {
      player.play()
    }
  }
}
