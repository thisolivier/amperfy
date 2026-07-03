//
//  AuditionDeckBlendChip.swift
//  Amperfy
//
//  Discovery-D4: Blend chip + control panel (design doc
//  docs/ux/amperfy-needle-drop-deck-v1-design.md §5.4). This file is the
//  small top-bar chip; the expandable panel lives in
//  `AuditionDeckBlendPanel.swift`.
//

import AmperfyKit
import SwiftUI

/// Top-bar capsule button showing the current blend setting in words and
/// toggling the blend control panel. Purely presentational + a binding —
/// it does not know about `AuditionDeckController`, so it can be built and
/// previewed independently of the deck-container agent's work.
public struct AuditionDeckBlendChip: View {
  let blend: Double
  let degradedPools: Set<DeckPool>
  @Binding var isPanelExpanded: Bool

  public init(blend: Double, degradedPools: Set<DeckPool>, isPanelExpanded: Binding<Bool>) {
    self.blend = blend
    self.degradedPools = degradedPools
    self._isPanelExpanded = isPanelExpanded
  }

  /// Design §5.4: "Familiar" (<0.33), "Balanced" (0.33–0.67), "Adventurous" (>0.67).
  var label: String {
    switch blend {
    case ..<0.33: "Familiar"
    case 0.33...0.67: "Balanced"
    default: "Adventurous"
    }
  }

  public var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) {
        isPanelExpanded.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "slider.horizontal.3")
        Text(label)
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(alignment: .topTrailing) {
        if !degradedPools.isEmpty {
          Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .offset(x: 2, y: -2)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Blend: \(label)")
    .accessibilityValue(degradedPools.isEmpty ? "" : "Some recommendation sources unavailable")
    .accessibilityHint(isPanelExpanded ? "Double tap to close blend controls" : "Double tap to open blend controls")
  }
}
