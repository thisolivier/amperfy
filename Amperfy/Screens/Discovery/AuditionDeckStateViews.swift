import SwiftUI

// MARK: - AuditionDeckDealingView

/// Dealing state (design §4.2): one skeleton card (shimmering artwork block, bar skeleton) +
/// centered `ProgressView` with "Dealing your deck…".
struct AuditionDeckDealingView: View {
  var body: some View {
    VStack(spacing: 20) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.white.opacity(0.12))
        .frame(width: UIScreen.main.bounds.width * 0.65)
        .aspectRatio(1, contentMode: .fit)

      Capsule()
        .fill(.white.opacity(0.12))
        .frame(height: 44)

      ProgressView("Dealing your deck…")
        .tint(.white)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - AuditionDeckEmptyView

/// Empty state (design §4.2): `ContentUnavailableView` + the blend slider rendered inline
/// beneath it (`AuditionDeckBlendSlider`, the blend-panel agent's file, used directly — moving it
/// re-deals per §3.1's "Empty -- slider moved --> Dealing").
struct AuditionDeckEmptyView: View {
  @Binding var blend: Double
  let onBlendSettled: (Double) -> ()

  var body: some View {
    VStack(spacing: 24) {
      ContentUnavailableView(
        "Nothing to deal",
        systemImage: "rectangle.stack.badge.questionmark",
        description: Text("Try moving the blend toward Adventurous.")
      )
      AuditionDeckBlendSlider(blend: $blend, onSettled: onBlendSettled)
        .padding(.horizontal, 24)
    }
    .foregroundStyle(.white)
  }
}

// MARK: - AuditionDeckErrorView

/// Error state (design §4.2): `ContentUnavailableView` + "Retry" button. Only reached when both
/// pools are unreachable — a single dead pool is the Populated + degraded-pool-banner case
/// (§8), never this.
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
    .foregroundStyle(.white)
  }
}
