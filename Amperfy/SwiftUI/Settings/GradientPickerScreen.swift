//
//  GradientPickerScreen.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 20 — Theme settings restructure).
//  Copyright (c) 2026 Olivier Butler. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - GradientPickerScreen

/// PR 20: pushed gradient picker for a single mode. Replaces the
/// Build-38 `.sheet(item:)`-based `GradientEditorView`, which collapsed
/// its own presentation chain (and the parent Settings modal's) on open.
/// This screen is a plain `NavigationLink` destination: no sheets, no
/// confirmation dialogs.
///
/// Two-stop only — start + end color pickers. Live-apply: every
/// mutation writes to `ThemeStore.setActiveGradient(...)` immediately
/// so the app's backgrounds update without a commit button.
struct GradientPickerScreen: View {
  let style: UIUserInterfaceStyle

  @State
  private var startColor: Color
  @State
  private var endColor: Color
  @State
  private var direction: ThemeGradient.Direction
  @State
  private var gradientHistory: [ThemeGradient]
  @State
  private var isSuppressingLiveApply = false

  init(style: UIUserInterfaceStyle) {
    self.style = style
    let seed = ThemeStore.shared.activeGradient(for: style)
      ?? ThemeGradient.builtInPresets.first!
    let reducedColors = seed.reducedToTwoStops().colors
    let firstHex = reducedColors.first ?? "#FFFFFF"
    let lastHex = reducedColors.last ?? reducedColors.first ?? "#000000"
    _startColor = State(initialValue: Color(UIColor(hex: firstHex) ?? .white))
    _endColor = State(initialValue: Color(UIColor(hex: lastHex) ?? .black))
    _direction = State(initialValue: seed.direction)
    _gradientHistory = State(initialValue: ThemeStore.shared.gradientHistory)
  }

  var body: some View {
    SettingsList {
      SettingsSection {
        // Live preview strip; mirrors the inflight picker state so the
        // user sees their change before popping back to the mode screen.
        GradientPreviewSwiftUIView(
          colors: [startColor, endColor],
          direction: direction
        )
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .listRowInsets(EdgeInsets())
        .padding(.vertical, 4)
      }

      SettingsSection(content: {
        ColorPicker(selection: $startColor, supportsOpacity: false) {
          Text("Start Color")
        }
        .onChange(of: startColor) { _ in applyLive() }
        ColorPicker(selection: $endColor, supportsOpacity: false) {
          Text("End Color")
        }
        .onChange(of: endColor) { _ in applyLive() }
      }, header: "Colors")

      SettingsSection(content: {
        Picker("Direction", selection: $direction) {
          ForEach(ThemeGradient.Direction.allCases, id: \.self) { dir in
            Text(directionLabel(dir)).tag(dir)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .onChange(of: direction) { _ in applyLive() }
      }, header: "Direction")

      if !gradientHistory.isEmpty {
        SettingsSection(content: {
          previouslyUsedCarousel
        }, header: "Previously Used")
      }

      SettingsSection {
        SettingsButtonRow(title: "Clear Gradient", actionType: .destructive) {
          clearGradient()
        }
      }
    }
    .navigationTitle(style == .dark ? "Dark Gradient" : "Light Gradient")
    .navigationBarTitleDisplayMode(.inline)
  }

  // MARK: - Previously-Used carousel

  private var previouslyUsedCarousel: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(gradientHistory, id: \.id) { gradient in
          Button {
            applyHistoryGradient(gradient)
          } label: {
            GradientPreviewSwiftUIView(
              colors: gradient.swiftUIColors,
              direction: gradient.direction
            )
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Mutations

  /// Called on every picker / direction change. Writes the new gradient
  /// to ThemeStore and fires the theme-change notification so the app's
  /// `GradientBackgroundView` instances redraw immediately.
  private func applyLive() {
    guard !isSuppressingLiveApply else { return }
    let hexColors = [UIColor(startColor).hexString, UIColor(endColor).hexString]
    let gradient = ThemeGradient(colors: hexColors, direction: direction)
    ThemeStore.shared.setActiveGradient(gradient, for: style)
    gradientHistory = ThemeStore.shared.gradientHistory
    postThemeChange()
  }

  /// Tap handler for a Previously-Used swatch. Applies that gradient to
  /// the current mode + stays on this screen (designer default Q3:
  /// apply-and-stay). Sets the pickers to the new start / end so the
  /// user can iterate further.
  private func applyHistoryGradient(_ gradient: ThemeGradient) {
    // Suppress the cascade of `onChange` handlers while we re-seed the
    // three pickers — otherwise each state mutation fires a fresh
    // applyLive() with intermediate state and writes three garbage
    // entries into history. One write, at the end, with the final shape.
    isSuppressingLiveApply = true
    let reduced = gradient.reducedToTwoStops()
    if let firstHex = reduced.colors.first,
       let uiFirst = UIColor(hex: firstHex) {
      startColor = Color(uiFirst)
    }
    if let lastHex = reduced.colors.last,
       let uiLast = UIColor(hex: lastHex) {
      endColor = Color(uiLast)
    }
    direction = reduced.direction
    isSuppressingLiveApply = false
    ThemeStore.shared.setActiveGradient(reduced, for: style)
    gradientHistory = ThemeStore.shared.gradientHistory
    postThemeChange()
  }

  private func clearGradient() {
    ThemeStore.shared.setActiveGradient(nil, for: style)
    postThemeChange()
  }

  private func postThemeChange() {
    ThemeStore.shared.postChangeNotification()
    (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
  }

  private func directionLabel(_ direction: ThemeGradient.Direction) -> String {
    switch direction {
    case .topToBottom: return "Top to Bottom"
    case .bottomToTop: return "Bottom to Top"
    case .leftToRight: return "Left to Right"
    case .rightToLeft: return "Right to Left"
    case .topLeftToBottomRight: return "Top-Left to Bottom-Right"
    case .topRightToBottomLeft: return "Top-Right to Bottom-Left"
    }
  }
}

// MARK: - GradientPickerScreen_Previews

struct GradientPickerScreen_Previews: PreviewProvider {
  static var previews: some View {
    NavigationView {
      GradientPickerScreen(style: .light)
    }
  }
}
