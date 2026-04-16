//
//  PresetPickerView.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 17.5 — Styling presets).
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

// MARK: - PresetPickerView

/// List of saved presets. `scope` controls which fields are applied on tap.
struct PresetPickerView: View {
  enum Scope {
    case full
    case lightSlice
    case darkSlice
  }

  let scope: Scope

  @Environment(\.dismiss)
  private var dismiss

  @State
  private var presets: [StylingPreset] = StylingPresetStore.shared.presets

  @State
  private var presetPendingDelete: StylingPreset?
  @State
  private var showDeleteAlert = false
  @State
  private var presetPendingRename: StylingPreset?
  @State
  private var renameFieldText = ""
  @State
  private var showRenameAlert = false

  var body: some View {
    Group {
      if presets.isEmpty {
        emptyStateView
      } else {
        presetList
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(
      NotificationCenter.default.publisher(
        for: StylingPresetStore.didChangeNotification
      )
    ) { _ in
      presets = StylingPresetStore.shared.presets
    }
    .alert(
      "Delete Preset?",
      isPresented: $showDeleteAlert,
      presenting: presetPendingDelete
    ) { pendingPreset in
      Button("Delete", role: .destructive) {
        StylingPresetStore.shared.deletePreset(pendingPreset)
      }
      Button("Cancel", role: .cancel) {}
    } message: { pendingPreset in
      Text(
        "Delete preset '\(StylingPresetStore.shared.displayName(for: pendingPreset))'? This cannot be undone."
      )
    }
    .alert("Rename Preset", isPresented: $showRenameAlert) {
      TextField(
        renamePlaceholder,
        text: $renameFieldText
      )
      Button("Save") {
        if let presetToRename = presetPendingRename {
          StylingPresetStore.shared.renamePreset(
            presetToRename,
            to: renameFieldText.isEmpty ? nil : renameFieldText
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Enter a new name, or leave blank to use the auto-label.")
    }
  }

  // MARK: - Sub-views

  private var emptyStateView: some View {
    VStack {
      Spacer()
      Text("No presets yet. Save your current theme from the Custom Theme screen.")
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
        .padding()
      Spacer()
    }
  }

  private var presetList: some View {
    List {
      ForEach(presets) { preset in
        presetRow(for: preset)
          .contentShape(Rectangle())
          .onTapGesture {
            applyPreset(preset)
            dismiss()
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
              presetPendingDelete = preset
              showDeleteAlert = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .contextMenu {
            Button {
              presetPendingRename = preset
              renameFieldText = preset.name ?? ""
              showRenameAlert = true
            } label: {
              Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
              presetPendingDelete = preset
              showDeleteAlert = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
      }
    }
  }

  @ViewBuilder
  private func presetRow(for preset: StylingPreset) -> some View {
    HStack(spacing: 10) {
      // Light swatch
      swatchView(for: preset.config.light)
        .frame(width: 36, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color(.separator), lineWidth: 0.5)
        )
      // Dark swatch
      swatchView(for: preset.config.dark)
        .frame(width: 36, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color(.separator), lineWidth: 0.5)
        )
      VStack(alignment: .leading, spacing: 2) {
        Text(StylingPresetStore.shared.displayName(for: preset))
          .font(.body)
        Text(secondaryLabel(for: preset))
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func swatchView(for modeSlice: ModeSlice) -> some View {
    if let gradient = modeSlice.gradient {
      GradientPreviewSwiftUIView(
        colors: gradient.swiftUIColors,
        direction: gradient.direction
      )
    } else if let backgroundHexValue = modeSlice.backgroundHex,
              let resolvedColor = UIColor(hex: backgroundHexValue) {
      Rectangle().fill(Color(resolvedColor))
    } else {
      Rectangle().fill(Color(.secondarySystemBackground))
    }
  }

  private func secondaryLabel(for preset: StylingPreset) -> String {
    let relativeTimeString = RelativeDateTimeFormatter().localizedString(
      for: preset.createdAt,
      relativeTo: Date()
    )
    let hasGradient =
      preset.config.light.gradient != nil || preset.config.dark.gradient != nil
    let typeTag = hasGradient ? "gradient" : "solid"
    return "\(relativeTimeString) · \(typeTag)"
  }

  private var navigationTitle: String {
    switch scope {
    case .full: return "Load Preset"
    case .lightSlice: return "Load Preset (Light)"
    case .darkSlice: return "Load Preset (Dark)"
    }
  }

  private var renamePlaceholder: String {
    guard let preset = presetPendingRename else { return "Preset name" }
    return StylingPresetStore.shared.displayName(for: preset)
  }

  // MARK: - Apply

  private func applyPreset(_ preset: StylingPreset) {
    switch scope {
    case .full:
      StylingPresetStore.shared.loadFullPreset(preset)
    case .lightSlice:
      StylingPresetStore.shared.loadLightSlice(from: preset)
    case .darkSlice:
      StylingPresetStore.shared.loadDarkSlice(from: preset)
    }
    (UIApplication.shared.delegate as? AppDelegate)?.applyCustomThemeAndReload()
  }
}

// MARK: - PresetPickerView_Previews

struct PresetPickerView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationView {
      PresetPickerView(scope: .full)
    }
  }
}
