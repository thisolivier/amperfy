import SwiftUI

// MARK: - AuditionDeckDealingView

/// Dealing state (design §4.2): one skeleton card (artwork block, bar skeleton) + centered
/// `ProgressView` with "Dealing your deck…". Deck v2: neutral system styling — the page respects
/// the app theme, no forced-dark styling.
struct AuditionDeckDealingView: View {
  var body: some View {
    VStack(spacing: 20) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.quaternary)
        .frame(width: UIScreen.main.bounds.width * 0.65)
        .aspectRatio(1, contentMode: .fit)

      Capsule()
        .fill(.quaternary)
        .frame(height: 44)

      ProgressView("Dealing your deck…")
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - AuditionDeckEmptyView

/// Empty state (design §4.2). Deck v2: the blend slider is gone (blend UI removed; sourcing is
/// sidecar-first with silent on-device fallback), so this is a plain empty message.
struct AuditionDeckEmptyView: View {
  var body: some View {
    ContentUnavailableView(
      "Nothing to deal",
      systemImage: "rectangle.stack.badge.questionmark",
      description: Text("No similar collections found for this seed.")
    )
  }
}

// MARK: - AuditionDeckErrorView

/// Error state (design §4.2): `ContentUnavailableView` + "Retry" button. Only reached when both
/// pools are unreachable — a single dead pool falls back silently (Deck v2), never this.
struct AuditionDeckErrorView: View {
  let message: String
  let onRetry: () -> ()

  var body: some View {
    ContentUnavailableView {
      Label("Couldn't deal a deck", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Retry", action: onRetry)
        .buttonStyle(.borderedProminent)
    }
  }
}
