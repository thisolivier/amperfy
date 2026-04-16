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

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - ThemeSettingsSection

struct ThemeSettingsSection: View {
  @State
  private var isEnabled: Bool = ThemeStore.shared.isEnabled
  @State
  private var lightGradient: ThemeGradient? = ThemeStore.shared.activeGradient(for: .light)
  @State
  private var darkGradient: ThemeGradient? = ThemeStore.shared.activeGradient(for: .dark)
  @State
  private var gradientHistory: [ThemeGradient] = ThemeStore.shared.gradientHistory
  @State
  private var editorTarget: EditorTarget?
  @State
  private var pendingHistoryGradient: ThemeGradient?
  @State
  private var showHistoryActionSheet = false
  @State
  private var lightBackground: Color = Self.loadColor(
    \.lightBackground,
    fallbackStyle: .light,
    fallbackSystem: .systemBackground
  )
  @State
  private var lightHeadingText: Color = Self.loadColor(
    \.lightHeadingText,
    fallbackStyle: .light,
    fallbackSystem: .label
  )
  @State
  private var lightText: Color = Self.loadColor(
    \.lightText,
    fallbackStyle: .light,
    fallbackSystem: .label
  )
  @State
  private var lightTint: Color = Self.loadColor(
    \.lightTint,
    fallbackStyle: .light,
    fallbackSystem: .systemBlue
  )
  @State
  private var darkBackground: Color = Self.loadColor(
    \.darkBackground,
    fallbackStyle: .dark,
    fallbackSystem: .systemBackground
  )
  @State
  private var darkHeadingText: Color = Self.loadColor(
    \.darkHeadingText,
    fallbackStyle: .dark,
    fallbackSystem: .label
  )
  @State
  private var darkText: Color = Self.loadColor(
    \.darkText,
    fallbackStyle: .dark,
    fallbackSystem: .label
  )
  @State
  private var darkTint: Color = Self.loadColor(
    \.darkTint,
    fallbackStyle: .dark,
    fallbackSystem: .systemBlue
  )
  @State
  private var selectedFontFamily: String = ThemeStore.shared.fontFamily ?? "System Default"
  @State
  private var showResetAlert = false
  @State
  private var contrastWarning: String?

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

  var body: some View {
    Group {
      mainContent
    }
    .sheet(item: $editorTarget) { target in
      GradientEditorView(
        initialGradient: target.style == .dark ? darkGradient : lightGradient,
        targetStyle: target.style
      ) { edited in
        applyGradient(edited, for: target.style)
      }
    }
    .confirmationDialog(
      "Use this gradient for…",
      isPresented: $showHistoryActionSheet,
      titleVisibility: .visible
    ) {
      Button("Light Mode") {
        if let gradient = pendingHistoryGradient {
          applyGradient(gradient, for: .light)
        }
        pendingHistoryGradient = nil
      }
      Button("Dark Mode") {
        if let gradient = pendingHistoryGradient {
          applyGradient(gradient, for: .dark)
        }
        pendingHistoryGradient = nil
      }
      Button("Cancel", role: .cancel) {
        pendingHistoryGradient = nil
      }
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    SettingsSection(content: {
      SettingsRow(title: "Custom Theme") {
        Toggle(isOn: $isEnabled) {}
          .toggleStyle(.switch)
          .onChange(of: isEnabled) { newValue in
            if newValue {
              ThemeStore.shared.populateDefaultsIfNeeded()
              reloadColorsFromStore()
              reloadGradientsFromStore()
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
        colorRow(title: "Heading Color", color: $lightHeadingText) { uiColor in
          ThemeStore.shared.lightHeadingText = uiColor
          applyTheme()
        }
        colorRow(title: "Body Color", color: $lightText) { uiColor in
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
        colorRow(title: "Heading Color", color: $darkHeadingText) { uiColor in
          ThemeStore.shared.darkHeadingText = uiColor
          applyTheme()
        }
        colorRow(title: "Body Color", color: $darkText) { uiColor in
          ThemeStore.shared.darkText = uiColor
          applyTheme()
        }
        colorRow(title: "Tint", color: $darkTint) { uiColor in
          ThemeStore.shared.darkTint = uiColor
          applyTheme()
        }
      }, header: "Dark Mode Colors")

      SettingsSection(content: {
        gradientModeRow(
          title: "Light Mode Gradient",
          gradient: lightGradient,
          style: .light
        )
        gradientModeRow(
          title: "Dark Mode Gradient",
          gradient: darkGradient,
          style: .dark
        )
        if !gradientHistory.isEmpty {
          previouslyUsedCarousel
        }
      }, header: "Background Gradient")

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
            reloadGradientsFromStore()
            applyTheme()
          }
        } message: {
          Text("This will clear all custom colors and fonts and restore the default appearance.")
        }
      }
    }
  }

  // MARK: - Gradient UX

  /// Identifier for the active gradient editor sheet. Encodes which mode
  /// (light vs dark) the editor is targeting so the sheet knows where to
  /// route the applied gradient.
  private struct EditorTarget: Identifiable {
    let style: UIUserInterfaceStyle
    var id: Int { style == .dark ? 1 : 0 }
  }

  private func gradientModeRow(
    title: String,
    gradient: ThemeGradient?,
    style: UIUserInterfaceStyle
  )
    -> some View {
    Button {
      editorTarget = EditorTarget(style: style)
    } label: {
      HStack(spacing: 12) {
        gradientSwatch(gradient)
          .frame(width: 40, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color(.separator), lineWidth: 0.5)
          )
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundColor(.primary)
          Text(gradient == nil ? "Not set" : "\(gradient!.colors.count) colors")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
        if gradient != nil {
          Button(role: .destructive) {
            applyGradient(nil, for: style)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.borderless)
        }
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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

  private var previouslyUsedCarousel: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Previously Used")
        .font(.caption)
        .foregroundColor(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(gradientHistory, id: \.id) { gradient in
            Button {
              pendingHistoryGradient = gradient
              showHistoryActionSheet = true
            } label: {
              GradientPreviewSwiftUIView(
                colors: gradient.swiftUIColors,
                direction: gradient.direction
              )
              .frame(width: 56, height: 40)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(Color(.separator), lineWidth: 0.5)
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(.vertical, 4)
  }

  private func applyGradient(
    _ gradient: ThemeGradient?,
    for style: UIUserInterfaceStyle
  ) {
    ThemeStore.shared.setActiveGradient(gradient, for: style)
    if style == .dark {
      darkGradient = gradient
    } else {
      lightGradient = gradient
    }
    gradientHistory = ThemeStore.shared.gradientHistory
    applyTheme()
  }

  private func reloadGradientsFromStore() {
    lightGradient = ThemeStore.shared.activeGradient(for: .light)
    darkGradient = ThemeStore.shared.activeGradient(for: .dark)
    gradientHistory = ThemeStore.shared.gradientHistory
  }

  // MARK: - Color row

  private func colorRow(
    title: String,
    color: Binding<Color>,
    onChanged: @escaping (UIColor) -> ()
  )
    -> some View {
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
    lightBackground = Self.loadColor(
      \.lightBackground,
      fallbackStyle: .light,
      fallbackSystem: .systemBackground
    )
    lightHeadingText = Self.loadColor(
      \.lightHeadingText,
      fallbackStyle: .light,
      fallbackSystem: .label
    )
    lightText = Self.loadColor(\.lightText, fallbackStyle: .light, fallbackSystem: .label)
    lightTint = Self.loadColor(\.lightTint, fallbackStyle: .light, fallbackSystem: .systemBlue)
    darkBackground = Self.loadColor(
      \.darkBackground,
      fallbackStyle: .dark,
      fallbackSystem: .systemBackground
    )
    darkHeadingText = Self.loadColor(
      \.darkHeadingText,
      fallbackStyle: .dark,
      fallbackSystem: .label
    )
    darkText = Self.loadColor(\.darkText, fallbackStyle: .dark, fallbackSystem: .label)
    darkTint = Self.loadColor(\.darkTint, fallbackStyle: .dark, fallbackSystem: .systemBlue)
  }

  // MARK: - Contrast warning

  private func updateContrastWarning() {
    guard isEnabled else { contrastWarning = nil; return }
    var warnings = [String]()

    // PR 17.4: check BOTH heading and body tiers against the background;
    // surface independent warnings when both fall below WCAG AA 4.5.
    if let lightBg = ThemeStore.shared.lightBackground,
       let lightHd = ThemeStore.shared.lightHeadingText,
       ThemeStore.contrastRatio(between: lightBg, and: lightHd) < 4.5 {
      warnings.append("Light: low heading/background contrast")
    }
    if let lightBg = ThemeStore.shared.lightBackground,
       let lightTx = ThemeStore.shared.lightText,
       ThemeStore.contrastRatio(between: lightBg, and: lightTx) < 4.5 {
      warnings.append("Light: low body/background contrast")
    }
    if let lightBg = ThemeStore.shared.lightBackground,
       let lightTn = ThemeStore.shared.lightTint,
       ThemeStore.contrastRatio(between: lightBg, and: lightTn) < 3.0 {
      warnings.append("Light: tint close to background")
    }
    if let darkBg = ThemeStore.shared.darkBackground,
       let darkHd = ThemeStore.shared.darkHeadingText,
       ThemeStore.contrastRatio(between: darkBg, and: darkHd) < 4.5 {
      warnings.append("Dark: low heading/background contrast")
    }
    if let darkBg = ThemeStore.shared.darkBackground,
       let darkTx = ThemeStore.shared.darkText,
       ThemeStore.contrastRatio(between: darkBg, and: darkTx) < 4.5 {
      warnings.append("Dark: low body/background contrast")
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
  @Binding
  var selectedFamily: String
  @Environment(\.dismiss)
  private var dismiss

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
            .font(
              family == "System Default"
                ? .body
                : Font.custom(
                  UIFont.fontNames(forFamilyName: family).first ?? family,
                  size: UIFont.preferredFont(forTextStyle: .body).pointSize
                )
            )
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
