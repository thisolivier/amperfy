import AmperfyKit
import Combine
import Foundation

// MARK: - AuditionDeckCardAuditionModel

/// Per-card sprite-manifest fetch + live-slice republishing, owned as a `@StateObject` by
/// `AuditionDeckCardView`. Bridges `DeckSpriteManifestFetcher`'s result into D3a's
/// `NeedleDropSpriteAvailability` (so `NeedleDropBar` renders LoadingSprite/Unavailable/Ready
/// correctly) and republishes the shared `NeedleDropSpritePlayer`'s `currentSlice` so the card's
/// audition readout (design §5.2) can read it — `NeedleDropBar`'s own internal controller is not
/// `public`, so the sprite player (which is `public`) is the only externally-observable source of
/// "what slice is playing right now."
@MainActor
final class AuditionDeckCardAuditionModel: ObservableObject {
  @Published
  private(set) var availability: NeedleDropSpriteAvailability = .loading
  @Published
  private(set) var currentSlice: NeedleDropSlice?

  private(set) var spritePlayer: NeedleDropSpritePlayer?
  private var sliceSubscription: AnyCancellable?
  /// Set on a `.failed` (as opposed to `.unavailable`/404) fetch — design §8: "retry once
  /// automatically when the card next becomes current."
  private var hasFetchFailedOnce = false

  var auditionedTrackId: String? { currentSlice?.trackId }

  func load(
    candidateId: String,
    kind: DeckCandidateKind,
    account: Account,
    audio: AuditionDeckAudioCoordinator
  ) async {
    let result = await DeckSpriteManifestFetcher.fetch(
      collectionId: candidateId,
      kind: kind,
      account: account
    )
    apply(result, candidateId: candidateId, audio: audio)
  }

  func retryOnceIfNeeded(
    candidateId: String,
    kind: DeckCandidateKind,
    account: Account,
    audio: AuditionDeckAudioCoordinator
  ) async {
    guard hasFetchFailedOnce else { return }
    hasFetchFailedOnce = false
    let result = await DeckSpriteManifestFetcher.fetch(
      collectionId: candidateId,
      kind: kind,
      account: account
    )
    apply(result, candidateId: candidateId, audio: audio)
  }

  private func apply(
    _ result: DeckSpriteManifestResult,
    candidateId: String,
    audio: AuditionDeckAudioCoordinator
  ) {
    switch result {
    case let .ready(manifest):
      availability = .ready(manifest)
      let player = audio.spritePlayer(for: candidateId, manifest: manifest)
      spritePlayer = player
      sliceSubscription = player.$currentSlice.sink { [weak self] slice in
        self?.currentSlice = slice
      }
    case .unavailable:
      availability = .unavailable
    case .failed:
      hasFetchFailedOnce = true
      availability = .unavailable
    }
  }
}
