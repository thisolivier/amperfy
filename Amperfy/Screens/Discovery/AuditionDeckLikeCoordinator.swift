import AmperfyKit
import Foundation

// MARK: - AuditionDeckLikeCoordinator

/// Read-only bridge from a `DeckCandidate`'s `collectionId`/`kind` to its current like/favourite
/// state (design §5.2, OQ-2's settled resolution): albums via `Album.isFavorite` (existing
/// AmperfyKit Subsonic-star plumbing), playlists via `PinnedPlaylistStore.shared` (local-only;
/// Subsonic has no playlist star — this app's already-built OQ-2 resolution, reused as-is).
///
/// **Read-only by design:** the actual like *toggle* UI/mechanics for deck cards are owned by
/// `AuditionDeckLikeButton.swift` (the blend-panel/entry-points agent's file — found already
/// built, self-contained, and explicitly documented as droppable straight into
/// `AuditionDeckCardView`; using it directly avoids a duplicate heart-button implementation with
/// its own optimistic-update/revert/error-chip logic). This coordinator exists only so
/// `AuditionDeckController` can *observe* current like state for two things that button has no
/// way to report back to a parent: the liked-pinned-through-refresh rule (design §8) and the end
/// card's "liked <m>" session counter (design §5.5) — both implemented by polling this at the
/// moment they're needed rather than caching a value pushed from button taps.
@MainActor
final class AuditionDeckLikeCoordinator {
  private let storage: LibraryStorage
  private let account: Account

  init(storage: LibraryStorage, account: Account) {
    self.storage = storage
    self.account = account
  }

  func isLiked(_ candidate: DeckCandidate) -> Bool {
    switch candidate.kind {
    case .playlist:
      return PinnedPlaylistStore.shared.isPinned(candidate.collectionId)
    case .album:
      let album = storage.getAlbum(
        for: account,
        id: candidate.collectionId,
        isDetailFaultResolution: false
      )
      return album?.isFavorite ?? false
    }
  }
}
