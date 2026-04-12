//
//  ThemeSettingsSection.swift
//  Amperfy
//
//  Created by the Amperfy spike (Feature F — Custom Styling Phase 2).
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

import SwiftUI
import UIKit

// MARK: - ThemeSettingsSection

struct ThemeSettingsSection: View {
  @State private var isEnabled: Bool = ThemeStore.shared.isEnabled
  @State private var lightBackground: Color = Self.loadColor(\.lightBackground, fallbackStyle: .light, fallbackSystem: .systemBackground)
  @State private var lightText: Color = Self.loadColor(\.lightText, fallbackStyle: .light, fallbackSystem: .label)
  @State private var lightTint: Color = Self.loadColor(\.lightTint, fallbackStyle: .light, fallbackSystem: .systemBlue)
  @State private var darkBackground: Color = Self.loadColor(\.darkBackground, fallbackStyle: .dark, fallbackSystem: .systemBackground)
  @State private var darkText: Color = Self.loadColor(\.darkText, fallbackStyle: .dark, fallbackSystem: .label)
  @State private var darkTint: Color = Self.loadColor(\.darkTint, fallbackStyle: .dark, fallbackSystem: .systemBlue)
  @State private var selectedFontFamily: String = ThemeStore.shared.fontFamily ?? "System Default"
  @State private var showResetAlert = false
  @State private var contrastWarning: String?

  private static func loadColor(
    _ keyPath: KeyPath<ThemeStore, UIColor?>,
    fallbackStyle: UIUserInterfaceStyle,
    fallbackSystem: UIColor
  ) -> Color {
    if let stored = ThemeStore.shared[keyPath: keyPath] {
      return Color(stored)
    }
    return Color(fallbackSystem.resolvedColor(with: UITraitCollection(userInterfaceStyle: fallbackStyle)))
  }

  var body: some View {
    SettingsSection(content: {
      SettingsRow(title: "Custom Theme") {
        Toggle(isOn: $isEnabled) {}
          .toggleStyle(.switch)
          .onChange(of: isEnabled) { newValue in
            if newValue {
              ThemeStore.shared.populateDefaultsIfNeeded()
              reloadColorsFromStore()
            }
            ThemeStore.shared.isEnabled = newValue
            applyTheme()
          }
      }

      if isEnabled {
        if let warning = contrastWarning {
          Text(warning)
            .font(.caption)
            .foregroundColor(.orange)
            .padding(.vertical, 4)
        }
      }
    })

    if isEnabled {
      SettingsSection(content: {
        colorRow(title: "Background", color: $lightBackground) { uiColor in
          ThemeStore.shared.lightBackground = uiColor
          applyTheme()
        }
        colorRow(title: "Text", color: $lightText) { uiColor in
          ThemeStore.shared.lightText = uiColor
          applyTheme()
        }
        colorRow(title: "Tint", color: $lightTint) { uiColor in
          ThemeStore.shared.lightTint = uiColor
          applyTheme()
        }
      }, header: "Light Mode Colors")

      SettingsSection(content: {
        colorRow(title: "Background", color: $darkBackground) { uiColor in
          ThemeStore.shared.darkBackground = uiColor
          applyTheme()
        }
        colorRow(title: "Text", color: $darkText) { uiColor in
          ThemeStore.shared.darkText = uiColor
          applyTheme()
        }
        colorRow(title: "Tint", color: $darkTint) { uiColor in
          ThemeStore.shared.darkTint = uiColor
          applyTheme()
        }
      }, header: "Dark Mode Colors")

      SettingsSection(content: {
        NavigationLink {
          FontPickerView(selectedFamily: $selectedFontFamily)
        } label: {
          HStack {
            Text("Font Family")
            Spacer()
            Text(selectedFontFamily)
              .foregroundColor(.secondary)
          }
        }
        .onChange(of: selectedFontFamily) { newValue in
          ThemeStore.shared.fontFamily = newValue == "System Default" ? nil : newValue
          applyTheme()
        }
      }, header: "Font")

      SettingsSection {
        SettingsButtonRow(title: "Reset to Defaults", actionType: .destructive) {
          showResetAlert = true
        }
        .alert("Reset Theme?", isPresented: $showResetAlert) {
          Button("Cancel", role: .cancel) {}
          Button("Reset", role: .destructive) {
            ThemeStore.shared.resetToDefaults()
            isEnabled = false
            selectedFontFamily = "System Default"
            reloadColorsFromStore()
            applyTheme()
          }
        } message: {
          Text("This will clear all custom colors and fonts and restore the default appearance.")
        }
      }
    }
  }

  // MARK: - Color row

  private func colorRow(
    title: String,
    color: Binding<Color>,
    onChanged: @escaping (UIColor) -> Void
  ) -> some View {
    ColorPicker(selection: color, supportsOpacity: false) {
      Text(title)
    }
    .onChange(of: color.wrappedValue) { newValue in
      onChanged(UIColor(newValue))
      updateContrastWarning()
    }
  }

  // MARK: - Theme application

  private func applyTheme() {
    ThemeStore.shared.postChangeNotification()
    (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
    updateContrastWarning()
  }

  private func reloadColorsFromStore() {
    lightBackground = Self.loadColor(\.lightBackground, fallbackStyle: .light, fallbackSystem: .systemBackground)
    lightText = Self.loadColor(\.lightText, fallbackStyle: .light, fallbackSystem: .label)
    lightTint = Self.loadColor(\.lightTint, fallbackStyle: .light, fallbackSystem: .systemBlue)
    darkBackground = Self.loadColor(\.darkBackground, fallbackStyle: .dark, fallbackSystem: .systemBackground)
    darkText = Self.loadColor(\.darkText, fallbackStyle: .dark, fallbackSystem: .label)
    darkTint = Self.loadColor(\.darkTint, fallbackStyle: .dark, fallbackSystem: .systemBlue)
  }

  // MARK: - Contrast warning

  private func updateContrastWarning() {
    guard isEnabled else { contrastWarning = nil; return }
    var warnings = [String]()

    if let lightBg = ThemeStore.shared.lightBackground,
       let lightTx = ThemeStore.shared.lightText,
       ThemeStore.contrastRatio(between: lightBg, and: lightTx) < 4.5 {
      warnings.append("Light: low text/background contrast")
    }
    if let lightBg = ThemeStore.shared.lightBackground,
       let lightTn = ThemeStore.shared.lightTint,
       ThemeStore.contrastRatio(between: lightBg, and: lightTn) < 3.0 {
      warnings.append("Light: tint close to background")
    }
    if let darkBg = ThemeStore.shared.darkBackground,
       let darkTx = ThemeStore.shared.darkText,
       ThemeStore.contrastRatio(between: darkBg, and: darkTx) < 4.5 {
      warnings.append("Dark: low text/background contrast")
    }
    if let darkBg = ThemeStore.shared.darkBackground,
       let darkTn = ThemeStore.shared.darkTint,
       ThemeStore.contrastRatio(between: darkBg, and: darkTn) < 3.0 {
      warnings.append("Dark: tint close to background")
    }

    contrastWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
  }
}

// MARK: - FontPickerView

struct FontPickerView: View {
  @Binding var selectedFamily: String
  @Environment(\.dismiss) private var dismiss

  private var fontFamilies: [String] {
    ["System Default"] + UIFont.familyNames.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  var body: some View {
    List(fontFamilies, id: \.self) { family in
      Button {
        selectedFamily = family
        dismiss()
      } label: {
        HStack {
          Text(family)
            .font(family == "System Default"
              ? .body
              : Font.custom(family, size: UIFont.preferredFont(forTextStyle: .body).pointSize))
          Spacer()
          if family == selectedFamily {
            Image(systemName: "checkmark")
              .foregroundColor(.accentColor)
          }
        }
      }
      .foregroundColor(.primary)
    }
    .navigationTitle("Font Family")
    .navigationBarTitleDisplayMode(.inline)
  }
}
