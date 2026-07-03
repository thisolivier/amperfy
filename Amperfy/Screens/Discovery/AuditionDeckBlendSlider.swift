//
//  AuditionDeckBlendSlider.swift
//  Amperfy
//
//  Discovery-D4: the blend slider row used inside `AuditionDeckBlendPanel`
//  (design doc §5.4). Split out so the panel file stays under the project's
//  ~200-line convention.
//

import SwiftUI
import UIKit

/// `Slider(value:in:)` between "Familiar" and "Adventurous", with a light
/// impact haptic on crossing the 0.5 midpoint and a 400ms debounce before
/// telling the caller the value has "settled" (design §5.4: "On change:
/// debounce 400ms -> regenerate un-swiped cards").
struct AuditionDeckBlendSlider: View {
  @Binding
  var blend: Double
  let onSettled: (Double) -> ()

  @State
  private var debounceTask: Task<(), Never>?
  @State
  private var wasAboveMidpoint: Bool

  init(blend: Binding<Double>, onSettled: @escaping (Double) -> ()) {
    self._blend = blend
    self.onSettled = onSettled
    self._wasAboveMidpoint = State(initialValue: blend.wrappedValue >= 0.5)
  }

  var body: some View {
    VStack(spacing: 4) {
      Slider(value: $blend, in: 0 ... 1, step: 0.01) { editing in
        // Fire the debounced settle callback on release too, in case the
        // 400ms window hasn't elapsed yet when the user lifts their finger.
        if !editing { scheduleSettle() }
      }
      .onChange(of: blend) { _, newValue in
        handleMidpointHaptic(newValue)
        scheduleSettle()
      }
      .accessibilityValue(accessibilityBlendDescription)

      HStack {
        Text("Familiar").font(.caption)
        Spacer()
        Text("Adventurous").font(.caption)
      }
      .foregroundStyle(.secondary)
    }
    .onDisappear { debounceTask?.cancel() }
  }

  private var accessibilityBlendDescription: String {
    switch blend {
    case ..<0.33: "Familiar"
    case 0.33 ... 0.67: "Balanced"
    default: "Adventurous"
    }
  }

  private func handleMidpointHaptic(_ newValue: Double) {
    let isAboveMidpoint = newValue >= 0.5
    if isAboveMidpoint != wasAboveMidpoint {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    wasAboveMidpoint = isAboveMidpoint
  }

  private func scheduleSettle() {
    debounceTask?.cancel()
    let settledValue = blend
    debounceTask = Task {
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }
      onSettled(settledValue)
    }
  }
}
