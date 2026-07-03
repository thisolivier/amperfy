import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckView

/// The `fullScreenCover`-content root (design §5.1): vertical paging, blurred crossfading
/// background, top overlay bar, and all 6 lifecycle states (§4.2).
///
/// **Blend chip/panel integration:** `AuditionDeckBlendChip`/`AuditionDeckBlendPanel`/
/// `AuditionDeckBlendSlider` (the blend-panel agent's files) were already built, self-contained,
/// and explicitly documented as this view's integration seam by the time this was written, so
/// they're used directly rather than through a placeholder injection closure. If their signatures
/// change before the integration pass, the only edits needed are inside this file's `body` and
/// `AuditionDeckStateViews.swift`'s `AuditionDeckEmptyView`.
///
/// **"Open" navigation hook:** `onOpenCandidate` — `AuditionDeckHostVC` (pure UIKit) is
/// responsible for dismissing the deck and pushing the real detail screen; this view only reports
/// *which* candidate was opened.
struct AuditionDeckView: View {
  @ObservedObject var controller: AuditionDeckController
  let account: Account
  let onOpenCandidate: (DeckCandidate) -> ()
  let onRequestDismiss: () -> ()

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isBlendPanelExpanded = false

  private static let endCardId = "audition-deck-end-card"

  init(
    controller: AuditionDeckController,
    account: Account,
    onOpenCandidate: @escaping (DeckCandidate) -> (),
    onRequestDismiss: @escaping () -> ()
  ) {
    self.controller = controller
    self.account = account
    self.onOpenCandidate = onOpenCandidate
    self.onRequestDismiss = onRequestDismiss
  }

  var body: some View {
    ZStack {
      AuditionDeckBackgroundView(container: currentBackgroundContainer, theme: theme)
      paging
        .auditionDeckBlendPanelDismissOverlay(isExpanded: $isBlendPanelExpanded)
    }
    .safeAreaInset(edge: .top) { topBar }
    .preferredColorScheme(.dark)
  }

  private var topBar: some View {
    VStack(spacing: 0) {
      AuditionDeckTopBar(
        position: currentPosition,
        total: controller.candidates.count,
        isRefreshing: controller.isRefreshing,
        refreshBannerVisible: controller.refreshBannerVisible,
        blend: controller.blend,
        degradedPools: controller.degradedPools,
        isBlendPanelExpanded: $isBlendPanelExpanded,
        onClose: close
      )
      if isBlendPanelExpanded {
        AuditionDeckBlendPanel(
          blend: $controller.blend,
          degradedPools: controller.degradedPools,
          onBlendSettled: { _ in Task { await controller.refresh() } },
          onDealMore: { Task { await controller.dealMore() } }
        )
      }
    }
  }

  @ViewBuilder
  private var paging: some View {
    switch controller.uiState {
    case .dealing:
      AuditionDeckDealingView()
    case .empty:
      AuditionDeckEmptyView(
        blend: $controller.blend,
        onBlendSettled: { newBlend in Task { await controller.redeal(blend: newBlend) } }
      )
    case let .error(message):
      AuditionDeckErrorView(message: message, onRetry: { Task { await controller.redeal() } })
    case .populated, .refreshing, .extended:
      cardScrollView
    }
  }

  private var cardScrollView: some View {
    ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(Array(controller.candidates.enumerated()), id: \.element.id) { index, candidate in
          AuditionDeckCardView(
            controller: controller,
            candidate: candidate,
            isCurrent: controller.scrollPositionId == candidate.collectionId,
            position: index + 1,
            total: controller.candidates.count,
            account: account,
            onOpen: onOpenCandidate,
            onRequestDismiss: onRequestDismiss
          )
          .containerRelativeFrame(.vertical)
          .scrollTransition { content, phase in
            reduceMotion ? content : content
              .scaleEffect(phase.isIdentity ? 1 : 0.96)
              .opacity(phase.isIdentity ? 1 : 0.8)
          }
          .id(candidate.collectionId)
        }

        AuditionDeckEndCardView(
          auditionedCount: controller.sessionAuditionedCount,
          likedCount: controller.sessionLikedCount,
          dealMoreLabel: "Deal \(controller.deckLength) more",
          onDealMore: { Task { await controller.dealMore() } },
          onDone: close
        )
        .containerRelativeFrame(.vertical)
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

  private var currentBackgroundContainer: PlayableContainable? {
    guard let id = controller.scrollPositionId,
          let candidate = controller.candidates.first(where: { $0.id == id })
    else { return nil }
    return controller.resolveEntity(candidate)
  }

  private var theme: ThemePreference {
    appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference
  }

  private func close() {
    controller.deckWillClose()
    onRequestDismiss()
  }
}
