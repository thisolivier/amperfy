//
//  AuditionDeckBlendPanel.swift
//  Amperfy
//
//  Discovery-D4: blend control panel (design doc
//  docs/ux/amperfy-needle-drop-deck-v1-design.md §5.4). The main
//  integration seam with the deck-container agent's `AuditionDeckView` —
//  see the `init` doc comment below for the exact contract.
//

import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckBlendPanel

/// The expandable blend control panel shown under the deck's top bar when
/// the blend chip (`AuditionDeckBlendChip`) is tapped.
///
/// This view takes only primitives, a binding, and callbacks — it has no
/// reference to `AuditionDeckController` — so it can be built and unit
/// previewed independently of the deck-container agent's work, and slotted
/// into `AuditionDeckView` once both land.
///
/// **Presentation contract** (the parent, i.e. `AuditionDeckView`, owns
/// this): conditionally include the panel in the view tree when expanded
/// (e.g. `if isPanelExpanded { AuditionDeckBlendPanel(...) }` inside a
/// `.safeAreaInset(edge: .top)`), wrapped in `withAnimation` on the
/// triggering state change so the panel's own `.transition` below takes
/// effect. **Dismiss-on-tap-outside** is not self-hosted by this view
/// (it's an inset, not a full-screen overlay, so it can't correctly
/// z-order a full-bleed tap catcher itself) — apply the
/// `.auditionDeckBlendPanelDismissOverlay(isExpanded:)` view modifier
/// (bottom of this file) to the deck's background/card content instead.
public struct AuditionDeckBlendPanel: View {
  @Binding
  var blend: Double
  let degradedPools: Set<DeckPool>
  let isBusy: Bool
  let onBlendSettled: (Double) -> ()
  let onDealMore: () -> ()

  @AppStorage("amperfy.fork.discovery.deckLength")
  private var deckLength: Int = 10
  @AppStorage("amperfy.fork.discovery.autoplayPreviews")
  private var autoplayPreviews: Bool = true

  /// - Parameters:
  ///   - blend: Current blend value, 0 (adjacency-only) ... 1 (similar-only).
  ///     Two-way binding since the slider mutates it live while dragging.
  ///   - degradedPools: Non-empty when one pool (adjacency/similar) is
  ///     currently unreachable (design §8) — drives the orange-dot chip
  ///     state and the panel's degraded-pool notice line.
  ///   - isBusy: True while the deck controller has a `refresh()` or
  ///     `dealMore()` already in flight (its `isRefreshing`/`isExtending`).
  ///     Disables "Deal <n> more" for the duration — both operations share a
  ///     single in-flight guard on the controller (re-entrancy fix), so a
  ///     second tap while one is running would otherwise just be silently
  ///     queued/ignored with no visible feedback; disabling the button is
  ///     the user-facing half of that guard.
  ///   - onBlendSettled: Fired ~400ms after the slider stops moving, with
  ///     the settled value. The caller (deck controller) is responsible for
  ///     regenerating un-swiped cards — this view has no deck knowledge.
  ///   - onDealMore: "Deal <n> more" tapped, where n is the persisted deck
  ///     length this view owns via `@AppStorage`.
  public init(
    blend: Binding<Double>,
    degradedPools: Set<DeckPool>,
    isBusy: Bool = false,
    onBlendSettled: @escaping (Double) -> (),
    onDealMore: @escaping () -> ()
  ) {
    self._blend = blend
    self.degradedPools = degradedPools
    self.isBusy = isBusy
    self.onBlendSettled = onBlendSettled
    self.onDealMore = onDealMore
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let notice = AuditionDeckDegradedPoolMessage.text(for: degradedPools) {
        Label(notice, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      AuditionDeckBlendSlider(blend: $blend, onSettled: onBlendSettled)

      VStack(alignment: .leading, spacing: 4) {
        Picker("Deck length", selection: $deckLength) {
          Text("5").tag(5)
          Text("10").tag(10)
          Text("20").tag(20)
        }
        .pickerStyle(.segmented)
        Text("Applies to the next deal")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Toggle("Auto-play previews", isOn: $autoplayPreviews)
        .font(.subheadline)

      Button("Deal \(deckLength) more", action: onDealMore)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .disabled(isBusy)
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .padding(.horizontal, 16)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

extension View {
  /// Invisible full-bleed tap catcher that collapses the blend panel when a
  /// tap lands outside it. See `AuditionDeckBlendPanel`'s doc comment for
  /// the full presentation contract this is part of.
  public func auditionDeckBlendPanelDismissOverlay(isExpanded: Binding<Bool>) -> some View {
    overlay {
      if isExpanded.wrappedValue {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
              isExpanded.wrappedValue = false
            }
          }
          .accessibilityHidden(true)
      }
    }
  }
}
