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
  private var showResetAlert = false
  @State
  private var showSavePresetAlert = false
  @State
  private var savePresetNameField = ""
  @State
  private var exportCopied = false
  @State
  private var showImportConfirm = false
  @State
  private var showImportError = false
  @State
  private var pendingImportConfig: StylingPresetConfig?

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
          SettingsButtonRow(title: "Save Current as Preset") {
            savePresetNameField = ""
            showSavePresetAlert = true
          }
          .alert("Save Preset", isPresented: $showSavePresetAlert) {
            TextField(
              "Preset \(StylingPresetStore.shared.nextAutoLabelIndex)",
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

        SettingsSection(content: {
          SettingsButtonRow(title: exportCopied ? "Copied!" : "Export Theme") {
            exportThemeJSON()
          }
          .disabled(exportCopied)
          SettingsButtonRow(title: "Import Theme") {
            importThemeJSON()
          }
          .alert("Apply Imported Theme?", isPresented: $showImportConfirm) {
            Button("Cancel", role: .cancel) { pendingImportConfig = nil }
            Button("Apply") {
              guard let config = pendingImportConfig else { return }
              StylingPresetStore.shared.applyFullConfig(config)
              (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
              isEnabled = true
              pendingImportConfig = nil
            }
          } message: {
            Text("This will overwrite your current theme settings with the imported theme.")
          }
          .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
          } message: {
            Text("Invalid theme JSON — check the format and try again.")
          }
        }, header: "Share")

        SettingsSection {
          SettingsButtonRow(title: "Reset to Defaults", actionType: .destructive) {
            showResetAlert = true
          }
          .alert("Reset Theme?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
              ThemeStore.shared.resetToDefaults()
              isEnabled = false
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

  private func exportThemeJSON() {
    let config = StylingPresetStore.shared.captureCurrentThemeState()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let jsonData = try? encoder.encode(config),
          let jsonString = String(data: jsonData, encoding: .utf8) else { return }
    UIPasteboard.general.string = jsonString
    withAnimation { exportCopied = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { exportCopied = false }
    }
  }

  private func importThemeJSON() {
    guard let clipboardString = UIPasteboard.general.string,
          let jsonData = clipboardString.data(using: .utf8) else {
      showImportError = true
      return
    }
    guard let config = try? JSONDecoder().decode(StylingPresetConfig.self, from: jsonData) else {
      showImportError = true
      return
    }
    pendingImportConfig = config
    showImportConfirm = true
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
