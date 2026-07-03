//
//  AuditionDeckLikeButton.swift
//  Amperfy
//
//  Discovery-D4: reusable like/heart control for an Audition Deck card
//  (design doc docs/ux/amperfy-needle-drop-deck-v1-design.md §5.2).
//

import AmperfyKit
import SwiftUI
import UIKit

/// Fetches the shared `AppDelegate` without going through the `View`
/// extension in `UtilitiesExtensions.swift` — that extension requires a
/// fully-initialized `self`, which isn't available yet inside this view's
/// `init` (where we read the initial liked state). Same underlying lookup,
/// just usable pre-`self`.
@MainActor
private var currentAppDelegate: AppDelegate {
  (UIApplication.shared.delegate as! AppDelegate)
}

// MARK: - AuditionDeckLikeButton

/// Heart-icon like control, branching on `DeckCandidateKind` per design
/// §5.2 / OQ-2: albums use the real Subsonic-star favourite plumbing
/// (`remoteToggleFavorite`, existing AmperfyKit API); playlists have no
/// Subsonic star, so they use the client-local `PinnedPlaylistStore` —
/// already the app's real local-only playlist-favourite mechanism (see
/// `PlaylistDetailVC.swift`'s heart button for the same pattern). The UI is
/// identical either way.
///
/// Deliberately takes only `collectionId` + `kind` + `account` (not a
/// reference to the deck-container agent's card/controller types) so it can
/// be dropped into `AuditionDeckCardView` without a build-order dependency
/// in either direction.
@MainActor
public struct AuditionDeckLikeButton: View {
  let collectionId: String
  let kind: DeckCandidateKind
  let account: Account

  @State
  private var liked: Bool
  @State
  private var couldNotSaveChipVisible = false

  public init(collectionId: String, kind: DeckCandidateKind, account: Account) {
    self.collectionId = collectionId
    self.kind = kind
    self.account = account
    switch kind {
    case .album:
      let album = currentAppDelegate.storage.main.library.getAlbum(
        for: account,
        id: collectionId,
        isDetailFaultResolution: false
      )
      self._liked = State(initialValue: album?.isFavorite ?? false)
    case .playlist:
      self._liked = State(initialValue: PinnedPlaylistStore.shared.isPinned(collectionId))
    }
  }

  public var body: some View {
    ZStack(alignment: .top) {
      Button(action: toggle) {
        Image(systemName: liked ? "heart.fill" : "heart")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(liked ? .pink : .white)
          .symbolEffect(.bounce, value: liked)
          .frame(width: 32, height: 32)
          .background(.ultraThinMaterial, in: Circle())
          // Visual circle is 32pt (design §5.2); pad the hit target to the
          // HIG-minimum 44pt without changing the visible size.
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(liked ? "Remove from Favourites" : "Add to Favourites")

      if couldNotSaveChipVisible {
        Text("Couldn't save favourite")
          .font(.caption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.ultraThinMaterial, in: Capsule())
          .offset(y: 48)
          .transition(.opacity)
          .accessibilityHidden(false)
      }
    }
  }

  private func toggle() {
    let previousLiked = liked
    withAnimation { liked.toggle() }

    switch kind {
    case .playlist:
      // Local-only store, no network round trip -> no failure path to
      // revert from (§5.2: UI is identical regardless of backing).
      PinnedPlaylistStore.shared.toggle(collectionId)
      if liked { fireLikeSuccessHaptic() }

    case .album:
      Task { @MainActor in
        guard let album = currentAppDelegate.storage.main.library.getAlbum(
          for: account,
          id: collectionId,
          isDetailFaultResolution: false
        ) else { return }
        let syncer = currentAppDelegate.getMeta(account.info).librarySyncer
        do {
          try await album.remoteToggleFavorite(syncer: syncer)
          if liked { fireLikeSuccessHaptic() }
        } catch {
          withAnimation { liked = previousLiked }
          // `Album.remoteToggleFavorite` flips `isFavorite` optimistically
          // *before* the network call (see AmperfyKit/Storage/EntityWrappers
          // /Album.swift), so a failed sync leaves the persisted flag out of
          // step with the UI we just reverted. A second toggle call restores
          // it; if that also fails (e.g. still offline) the model stays
          // optimistically-flipped until the next real favourite sync — an
          // accepted edge case, matches this app's existing no-transaction
          // favourite-toggle behaviour elsewhere (EntityPreviewVC).
          try? await album.remoteToggleFavorite(syncer: syncer)
          await showCouldNotSaveChip()
        }
      }
    }
  }

  /// Design §7: "like success light impact" — fired once the like actually takes (playlist:
  /// immediately, no failure path; album: only after the remote favourite call succeeds, not on
  /// the optimistic flip that might get reverted). Direct `UIImpactFeedbackGenerator` call, no
  /// shared Haptics abstraction — matches this codebase's existing convention (confirmed absent in
  /// two prior sprints).
  private func fireLikeSuccessHaptic() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func showCouldNotSaveChip() async {
    withAnimation { couldNotSaveChipVisible = true }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    withAnimation { couldNotSaveChipVisible = false }
  }
}
