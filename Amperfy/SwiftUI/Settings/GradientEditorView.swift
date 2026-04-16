//
//  GradientEditorView.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 17.2 — Gradient backgrounds).
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

// MARK: - GradientEditorView

/// SwiftUI sheet for composing / editing a `ThemeGradient`. Presented from
/// `ThemeSettingsSection` when the user taps the Light-Mode or Dark-Mode
/// gradient preview. Up to 4 color wells + a direction picker feed a live
/// preview; `Apply & Save` writes the result through `ThemeStore` and
/// dismisses. Simple dismiss discards any in-progress edits (preview-only).
struct GradientEditorView: View {
  let targetStyle: UIUserInterfaceStyle
  let onApply: (ThemeGradient) -> ()

  @Environment(\.dismiss)
  private var dismiss

  @State
  private var colors: [Color]
  @State
  private var direction: ThemeGradient.Direction

  init(
    initialGradient: ThemeGradient?,
    targetStyle: UIUserInterfaceStyle,
    onApply: @escaping (ThemeGradient) -> ()
  ) {
    self.targetStyle = targetStyle
    self.onApply = onApply
    let seed = initialGradient ?? ThemeGradient.builtInPresets.first!
    _colors = State(initialValue: seed.colors.compactMap {
      UIColor(hex: $0).map(Color.init)
    })
    _direction = State(initialValue: seed.direction)
  }

  var body: some View {
    NavigationView {
      Form {
        Section {
          GradientPreviewSwiftUIView(colors: colors, direction: direction)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 4)
        }

        Section(header: Text("Colors")) {
          ForEach(Array(colors.enumerated()), id: \.offset) { index, _ in
            HStack {
              ColorPicker(
                "Color \(index + 1)",
                selection: Binding(
                  get: { colors[index] },
                  set: { colors[index] = $0 }
                ),
                supportsOpacity: false
              )
              if colors.count > ThemeGradient.minColorCount {
                Button(role: .destructive) {
                  colors.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
              }
            }
          }
          if colors.count < ThemeGradient.maxColorCount {
            Button {
              colors.append(colors.last ?? .white)
            } label: {
              Label("Add Color", systemImage: "plus.circle")
            }
          }
        }

        Section(header: Text("Direction")) {
          Picker("Direction", selection: $direction) {
            ForEach(ThemeGradient.Direction.allCases, id: \.self) { direction in
              Text(directionLabel(direction)).tag(direction)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }

        Section {
          Button {
            applyAndDismiss()
          } label: {
            Text("Apply & Save")
              .frame(maxWidth: .infinity)
          }
          .disabled(colors.count < ThemeGradient.minColorCount)
        }
      }
      .navigationTitle(
        targetStyle == .dark ? "Edit Dark Mode Gradient" : "Edit Light Mode Gradient"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
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

  private func applyAndDismiss() {
    let hexColors = colors.map { UIColor($0).hexString }
    let gradient = ThemeGradient(colors: hexColors, direction: direction)
    onApply(gradient)
    dismiss()
  }
}

// MARK: - GradientPreviewSwiftUIView

/// SwiftUI preview of a gradient. Mirrors `ThemeGradient.Direction` to the
/// SwiftUI `LinearGradient` start/end unit points. Used inside the editor
/// sheet and the previously-used carousel rows.
struct GradientPreviewSwiftUIView: View {
  let colors: [Color]
  let direction: ThemeGradient.Direction

  var body: some View {
    let (start, end) = points(for: direction)
    LinearGradient(
      gradient: SwiftUI.Gradient(colors: colors),
      startPoint: start,
      endPoint: end
    )
  }

  private func points(for direction: ThemeGradient.Direction) -> (UnitPoint, UnitPoint) {
    switch direction {
    case .topToBottom: return (.top, .bottom)
    case .bottomToTop: return (.bottom, .top)
    case .leftToRight: return (.leading, .trailing)
    case .rightToLeft: return (.trailing, .leading)
    case .topLeftToBottomRight: return (.topLeading, .bottomTrailing)
    case .topRightToBottomLeft: return (.topTrailing, .bottomLeading)
    }
  }
}

// MARK: - ThemeGradient SwiftUI helper

extension ThemeGradient {
  /// Convenience: the gradient's hex colors mapped to SwiftUI `Color`s,
  /// skipping any that fail to parse. Used by preview/carousel rows.
  var swiftUIColors: [Color] {
    colors.compactMap { UIColor(hex: $0).map(Color.init) }
  }
}
