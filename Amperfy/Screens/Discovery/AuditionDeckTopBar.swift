import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckTopBar

/// Top overlay bar (design §5.1): close button, "n of m" counter (with an inline `ProgressView`
/// while Refreshing, per §4.2's Notes), and the blend chip (`AuditionDeckBlendChip`, the
/// blend-panel agent's file, used directly). Also renders the transient "Deck updated" chip
/// (§4.2: auto-dismiss 1.5s) just below the counter.
struct AuditionDeckTopBar: View {
  let position: Int
  let total: Int
  let isRefreshing: Bool
  let refreshBannerVisible: Bool
  let blend: Double
  let degradedPools: Set<DeckPool>
  @Binding
  var isBlendPanelExpanded: Bool
  let onClose: () -> ()

  var body: some View {
    VStack(spacing: 4) {
      HStack {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Close deck")

        Spacer()

        HStack(spacing: 6) {
          if isRefreshing {
            ProgressView().controlSize(.mini)
          }
          Text("\(position) of \(total)")
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)

        Spacer()

        AuditionDeckBlendChip(
          blend: blend, degradedPools: degradedPools, isPanelExpanded: $isBlendPanelExpanded
        )
      }

      if refreshBannerVisible {
        Text("Deck updated")
          .font(.caption2)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(.ultraThinMaterial, in: Capsule())
          .transition(.opacity)
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }
}
