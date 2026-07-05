import AmperfyKit
import Combine
import UIKit

// MARK: - AuditionDeckAudioCoordinator

/// Owns everything audio-behavior-shaped from design §6, updated for Deck v2 + triage A1:
/// - Main-player pause/resume handoff. Opening the deck leaves the main player ALONE
///   (user-settled 2026-07-05); it is paused only when sprite audio actually starts over it, and
///   resumed on page pop only if this session paused it and it is still paused at that moment —
///   the state machine itself is `AmperfyKit.DeckMainPlayerHandoff` (extracted for testability).
/// - The single-active-`NeedleDropSpritePlayer`-at-a-time invariant across cards.
/// - Stopping sprite audio synchronously on card swipe, page pop, a detail pushed over the deck
///   (`AuditionDeckHostVC.viewWillDisappear`), and app-background.
///
/// One instance is owned per deck session by `AuditionDeckController`. Deck v2 removed audition
/// tracking (user-settled 2026-07-03); a minimal `$isPlaying` observation was re-added for A1 —
/// it only feeds `DeckMainPlayerHandoff.spritePlaybackDidStart()`, no per-candidate bookkeeping.
@MainActor
final class AuditionDeckAudioCoordinator {
  private let mainPlayerHandoff: DeckMainPlayerHandoff

  private var spritePlayers: [String: NeedleDropSpritePlayer] = [:]
  /// One `$isPlaying` subscription per owned sprite player (created and released together with
  /// it), firing `mainPlayerHandoff.spritePlaybackDidStart()` on every play-start.
  private var spritePlayStartSubscriptions: [String: AnyCancellable] = [:]
  /// `nonisolated(unsafe)`: only read/written from `init`/`deinit` (never concurrently), and
  /// `deinit` on an `@MainActor` class is itself `nonisolated` by default in Swift 6 — matches the
  /// same accommodation already used elsewhere in this codebase (e.g.
  /// `AmperfyKit/Player/NeedleDrop/NeedleDropSpritePlayer.swift`) for state that's provably
  /// single-threaded in practice but not statically Sendable.
  nonisolated(unsafe) private var backgroundObserverToken: NSObjectProtocol?

  init(player: PlayerFacade) {
    // A1 (user-settled 2026-07-05): opening the deck does NOT pause the main player anymore —
    // the handoff pauses it only once sprite audio actually starts.
    self.mainPlayerHandoff = DeckMainPlayerHandoff(
      isMainPlayerPlaying: { player.isPlaying },
      pauseMainPlayer: { player.pause() },
      resumeMainPlayer: { player.play() }
    )
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
    // X-Deal-Id on the sprite-audio request too, so server logs correlate the
    // audio load with the deal that produced the card; player-item load
    // failures land in DiscoveryTelemetry (build-60: self-diagnosing previews).
    // In gateway mode (both URL + key set) the sprite URL already points at
    // {gateway}/adjacency/sprite-audio (rebased by DeckSpriteManifestFetcher),
    // so the AVURLAsset also needs the gateway's X-API-Key header.
    var httpHeaderFields: [String: String] = [:]
    if let dealId = DiscoveryTelemetry.shared.currentDealId {
      httpHeaderFields[DiscoveryTelemetry.dealIdHeaderName] = dealId
    }
    if let gatewayRoute = AdjacencyGatewaySettings.shared.activeRoute {
      httpHeaderFields[AdjacencyGatewayRoute.apiKeyHeaderName] = gatewayRoute.apiKey
    }
    let newPlayer = NeedleDropSpritePlayer(
      spriteURL: manifest.spriteURL,
      httpHeaderFields: httpHeaderFields.isEmpty ? nil : httpHeaderFields
    )
    let spriteURLString = manifest.spriteURL.absoluteString
    newPlayer.onItemFailed = { reason in
      DiscoveryTelemetry.shared.recordSpriteFetch(
        urlString: spriteURLString,
        outcome: "sprite player load failed: \(reason)",
        milliseconds: 0
      )
    }
    // A1: pause the main player the moment sprite audio actually starts (never on deck open).
    // `NeedleDropSpritePlayer` assigns `isPlaying = true` on every play-start transition, so
    // this also re-pauses real playback the user started from a detail pushed over the deck if
    // they come back and needle-drop again — sprite audio never plays over the main player.
    spritePlayStartSubscriptions[candidateId] = newPlayer.$isPlaying
      .filter { $0 }
      .sink { [weak self] _ in
        self?.mainPlayerHandoff.spritePlaybackDidStart()
      }
    spritePlayers[candidateId] = newPlayer
    return newPlayer
  }

  /// Card left the prefetch window (scrolled far away) — stop and release its player. Never
  /// releases the currently-current card even if asked, to avoid killing audio mid-transition.
  func releaseSpritePlayer(for candidateId: String, currentCandidateId: String?) {
    guard candidateId != currentCandidateId else { return }
    spritePlayers[candidateId]?.stop()
    spritePlayers.removeValue(forKey: candidateId)
    spritePlayStartSubscriptions.removeValue(forKey: candidateId)
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
  /// — stops all sprite audio, then resumes the main player only if this deck session paused it
  /// (first sprite play) and it is still paused now. A main player that is PLAYING at close time
  /// (e.g. the user started real playback from a detail screen pushed over the deck) is never
  /// touched — see `DeckMainPlayerHandoff`.
  func deckWillClose() {
    stopAllSpritePlayers()
    mainPlayerHandoff.deckWillClose()
  }
}
