//
//  CustomThemeRootView.swift
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

// MARK: - CustomThemeRootView

/// PR 20: top-level Custom Theme screen reached from Settings root. Replaces
/// the inline `ThemeSettingsSection` that used to live inside
/// `DisplaySettingsView`. Splits the flat Light/Dark color grids into two
/// pushed detail screens (`ModeDetailView`), hosts the font picker nav link,
/// the PR 17.3 Album-Art border section, and the destructive Reset action.
struct CustomThemeRootView: View {
  @State
  private var isEnabled: Bool = ThemeStore.shared.isEnabled
  @State
  private var selectedFontFamily: String = ThemeStore.shared.fontFamily ?? "System Default"
  @State
  private var borderWidth: Double = .init(ThemeStore.shared.albumArtBorderWidth)
  @State
  private var borderColor: Color = CustomThemeRootView.initialBorderColor()
  @State
  private var hasCustomBorderColor: Bool = ThemeStore.shared.albumArtBorderColor != nil
  @State
  private var showResetAlert = false
  @State
  private var showSavePresetAlert = false
  @State
  private var savePresetNameField = ""

  private static func initialBorderColor() -> Color {
    if let stored = ThemeStore.shared.albumArtBorderColor {
      return Color(stored)
    }
    return Color(UIColor.separator)
  }

  var body: some View {
    SettingsList {
      SettingsSection {
        SettingsRow(title: "Custom Theme") {
          Toggle(isOn: $isEnabled) {}
            .toggleStyle(.switch)
            .onChange(of: isEnabled) { newValue in
              if newValue {
                ThemeStore.shared.populateDefaultsIfNeeded()
              }
              ThemeStore.shared.isEnabled = newValue
              applyTheme()
            }
        }
      }

      if isEnabled {
        SettingsSection {
          NavigationLink {
            ModeDetailView(style: .light)
          } label: {
            Text("Light Mode")
          }
          NavigationLink {
            ModeDetailView(style: .dark)
          } label: {
            Text("Dark Mode")
          }
        }

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
        }, header: "Typography")

        SettingsSection(content: {
          SettingsRow(title: "Border Width") {
            // Stepper: cheap, clamps naturally on 0...6, gives a discrete
            // value for the preview. Slider would be fiddly inside a
            // grouped-inset row and wouldn't snap nicely to integers.
            HStack(spacing: 8) {
              Text("\(Int(borderWidth)) pt")
                .foregroundColor(.secondary)
                .monospacedDigit()
              Stepper("", value: $borderWidth, in: 0 ... 6, step: 1)
                .labelsHidden()
                .onChange(of: borderWidth) { newValue in
                  ThemeStore.shared.albumArtBorderWidth = CGFloat(newValue)
                  applyTheme()
                }
            }
          }
          ColorPicker(selection: $borderColor, supportsOpacity: false) {
            Text("Border Color")
          }
          .onChange(of: borderColor) { newValue in
            hasCustomBorderColor = true
            ThemeStore.shared.albumArtBorderColor = UIColor(newValue)
            applyTheme()
          }
        }, header: "Album Art")

        SettingsSection(content: {
          SettingsButtonRow(title: "Save Current as Preset") {
            let nextAutoLabelIndex = StylingPresetStore.shared.presets.count + 1
            savePresetNameField = ""
            // Trigger the alert — placeholder shows next auto-label index.
            _ = nextAutoLabelIndex // used in alert placeholder below
            showSavePresetAlert = true
          }
          .alert("Save Preset", isPresented: $showSavePresetAlert) {
            TextField(
              "Preset \(StylingPresetStore.shared.presets.count + 1)",
              text: $savePresetNameField
            )
            Button("Save") {
              StylingPresetStore.shared.savePreset(
                name: savePresetNameField.trimmingCharacters(in: .whitespaces).isEmpty
                  ? nil
                  : savePresetNameField
              )
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("Name your theme snapshot, or leave blank for an auto-label.")
          }
          NavigationLink {
            PresetPickerView(scope: .full)
          } label: {
            Text("Load Preset")
          }
        }, header: "Presets")

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
              borderWidth = 0
              borderColor = Color(UIColor.separator)
              hasCustomBorderColor = false
              applyTheme()
            }
          } message: {
            Text(
              "This will clear all custom colors, fonts, gradients, and borders and restore the default appearance."
            )
          }
        }
      }
    }
    .navigationTitle("Custom Theme")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func applyTheme() {
    ThemeStore.shared.postChangeNotification()
    (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
  }
}

// MARK: - CustomThemeRootView_Previews

struct CustomThemeRootView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationView {
      CustomThemeRootView()
    }
  }
}
