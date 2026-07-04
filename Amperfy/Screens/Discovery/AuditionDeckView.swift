import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckView

/// Deck v2 root (docs/ux/amperfy-discovery-v3-backlog.md "Deck v2 redesign"): a pushed page —
/// transparent over `AuditionDeckHostVC`'s theme surface (gradient/solid, exactly as Home) —
/// with an accent-colored page title, a small corner card count, and vertically-paged
/// rounded-corner cards. No top bar, no close button (system back), no blend UI (the blend
/// machinery lives on in `DeckFusionEngine`; the deck sources sidecar-first internally).
///
/// `onOpenCandidate`: whole-card tap — `AuditionDeckHostVC` pushes the collection's detail onto
/// the same navigation stack while this deck stays alive beneath it. `onRequestDismiss`: the end
/// card's Done — the host pops this page.
struct AuditionDeckView: View {
  @ObservedObject
  var controller: AuditionDeckController
  let account: Account
  let pageTitle: String
  let accentColor: Color
  let onOpenCandidate: (DeckCandidate) -> ()
  let onRequestDismiss: () -> ()

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private static let endCardId = "audition-deck-end-card"

  var body: some View {
    paging
      .safeAreaInset(edge: .top) { header }
  }

  /// Page title in the account theme accent (RelatedTracksVC's header pattern), with the X/Y
  /// card count small and unobtrusive in the top-trailing corner.
  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(pageTitle)
        .font(.title3.bold())
        .foregroundStyle(accentColor)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)

      if !controller.candidates.isEmpty {
        Text("\(currentPosition)/\(controller.candidates.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .accessibilityLabel("Card \(currentPosition) of \(controller.candidates.count)")
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private var paging: some View {
    switch controller.uiState {
    case .dealing:
      AuditionDeckDealingView()
    case .empty:
      AuditionDeckEmptyView()
    case let .error(message):
      AuditionDeckErrorView(message: message, onRetry: { Task { await controller.redeal() } })
    case .extended, .populated, .refreshing:
      cardScrollView
    }
  }

  private var cardScrollView: some View {
    // Captured as a local `let` (rather than read directly inside `scrollTransition`'s closure
    // below): `scrollTransition`'s closure is `@Sendable`, and `reduceMotion` is a main-actor-
    // isolated `@Environment` property on this view — a plain local `Bool` copy crosses that
    // boundary cleanly since `Bool` is `Sendable`.
    let reduceMotionSnapshot = reduceMotion
    return ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(Array(controller.candidates.enumerated()), id: \.element.id) { index, candidate in
          AuditionDeckCardView(
            controller: controller,
            candidate: candidate,
            isCurrent: controller.scrollPositionId == candidate.collectionId,
            position: index + 1,
            total: controller.candidates.count,
            account: account,
            onOpen: onOpenCandidate
          )
          // Both axes: with only .vertical, the horizontal proposal is left
          // unspecified, so a card sizes to its ideal width — which overflows
          // the screen once the Needle Drop bar is Ready (segments + readout
          // give the card a large ideal width). Seen live as 730pt-wide cards
          // on a 402pt screen during the solo QA round.
          .containerRelativeFrame([.horizontal, .vertical])
          .scrollTransition { content, phase in
            content
              .scaleEffect(reduceMotionSnapshot || phase.isIdentity ? 1 : 0.96)
              .opacity(reduceMotionSnapshot || phase.isIdentity ? 1 : 0.8)
          }
          .id(candidate.collectionId)
        }

        AuditionDeckEndCardView(
          likedCount: controller.sessionLikedCount,
          dealMoreLabel: "Deal \(controller.deckLength) more",
          onDealMore: { Task { await controller.dealMore() } },
          onDone: onRequestDismiss
        )
        .containerRelativeFrame([.horizontal, .vertical])
        .id(Self.endCardId)
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $controller.scrollPositionId)
  }

  private var currentPosition: Int {
    guard let id = controller.scrollPositionId,
          let index = controller.candidates.firstIndex(where: { $0.id == id })
    else { return controller.candidates.count }
    return index + 1
  }
}
