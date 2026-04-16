//
//  ModeDetailView.swift
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

// MARK: - ModeDetailView

/// PR 20: per-mode detail screen pushed from `CustomThemeRootView`. Hosts
/// Background / Heading / Body / Tint color pickers plus a Gradient row
/// that pushes to `GradientPickerScreen`. A single instance is used for
/// both light and dark — parameterised by `style`.
struct ModeDetailView: View {
  let style: UIUserInterfaceStyle

  @State
  private var background: Color
  @State
  private var headingText: Color
  @State
  private var bodyText: Color
  @State
  private var tint: Color
  @State
  private var activeGradient: ThemeGradient?

  init(style: UIUserInterfaceStyle) {
    self.style = style
    let isDark = style == .dark
    _background = State(initialValue: Self.loadColor(
      isDark ? \.darkBackground : \.lightBackground,
      fallbackStyle: style,
      fallbackSystem: .systemBackground
    ))
    _headingText = State(initialValue: Self.loadColor(
      isDark ? \.darkHeadingText : \.lightHeadingText,
      fallbackStyle: style,
      fallbackSystem: .label
    ))
    _bodyText = State(initialValue: Self.loadColor(
      isDark ? \.darkText : \.lightText,
      fallbackStyle: style,
      fallbackSystem: .label
    ))
    _tint = State(initialValue: Self.loadColor(
      isDark ? \.darkTint : \.lightTint,
      fallbackStyle: style,
      fallbackSystem: .systemBlue
    ))
    _activeGradient = State(initialValue: ThemeStore.shared.activeGradient(for: style))
  }

  var body: some View {
    SettingsList {
      SettingsSection(content: {
        ColorPicker(selection: $background, supportsOpacity: false) {
          Text("Background")
        }
        .onChange(of: background) { newValue in
          writeColor(newValue, into: style == .dark ? \.darkBackground : \.lightBackground)
        }
        ColorPicker(selection: $headingText, supportsOpacity: false) {
          Text("Heading Color")
        }
        .onChange(of: headingText) { newValue in
          writeColor(newValue, into: style == .dark ? \.darkHeadingText : \.lightHeadingText)
        }
        ColorPicker(selection: $bodyText, supportsOpacity: false) {
          Text("Body Color")
        }
        .onChange(of: bodyText) { newValue in
          writeColor(newValue, into: style == .dark ? \.darkText : \.lightText)
        }
        ColorPicker(selection: $tint, supportsOpacity: false) {
          Text("Tint")
        }
        .onChange(of: tint) { newValue in
          writeColor(newValue, into: style == .dark ? \.darkTint : \.lightTint)
        }
      }, header: "Colors")

      SettingsSection(content: {
        NavigationLink {
          GradientPickerScreen(style: style)
            .onDisappear {
              // Re-sync the preview swatch when the picker pops back —
              // the picker live-applies, so the parent's gradient state
              // may be stale by the time we return.
              activeGradient = ThemeStore.shared.activeGradient(for: style)
            }
        } label: {
          HStack(spacing: 12) {
            gradientSwatch(activeGradient)
              .frame(width: 44, height: 28)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(Color(.separator), lineWidth: 0.5)
              )
            VStack(alignment: .leading, spacing: 2) {
              Text("Gradient")
              Text(activeGradient == nil ? "Not set" : "Custom gradient")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }
      }, header: "Gradient")
    }
    .navigationTitle(style == .dark ? "Dark Mode" : "Light Mode")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func gradientSwatch(_ gradient: ThemeGradient?) -> some View {
    if let gradient {
      GradientPreviewSwiftUIView(
        colors: gradient.swiftUIColors,
        direction: gradient.direction
      )
    } else {
      Rectangle()
        .fill(Color(.secondarySystemBackground))
    }
  }

  private func writeColor(
    _ newValue: Color,
    into keyPath: ReferenceWritableKeyPath<ThemeStore, UIColor?>
  ) {
    ThemeStore.shared[keyPath: keyPath] = UIColor(newValue)
    applyTheme()
  }

  private func applyTheme() {
    ThemeStore.shared.postChangeNotification()
    (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
  }

  // MARK: - Initial-load helper

  private static func loadColor(
    _ keyPath: KeyPath<ThemeStore, UIColor?>,
    fallbackStyle: UIUserInterfaceStyle,
    fallbackSystem: UIColor
  )
    -> Color {
    if let stored = ThemeStore.shared[keyPath: keyPath] {
      return Color(stored)
    }
    return Color(
      fallbackSystem
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: fallbackStyle))
    )
  }
}

// MARK: - ModeDetailView_Previews

struct ModeDetailView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationView {
      ModeDetailView(style: .light)
    }
  }
}
