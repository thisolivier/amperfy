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
//  PR 20: the sheet-based `GradientEditorView` was retired after it was
//  diagnosed as the root cause of the Build 38 gradient picker dismiss
//  cascade (a `.sheet(item:)` on a transient View identity inside a
//  `List` inside a `.formSheet` `UIHostingController`). The replacement
//  lives in `GradientPickerScreen.swift` as a plain NavigationLink push.
//
//  This file is kept for the two helpers still shared by the new picker,
//  the per-mode detail swatch, and the previously-used carousel:
//    1. `GradientPreviewSwiftUIView` — LinearGradient preview tile.
//    2. `ThemeGradient.swiftUIColors` — hex → SwiftUI.Color mapping.

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - GradientPreviewSwiftUIView

/// SwiftUI preview of a gradient. Mirrors `ThemeGradient.Direction` to the
/// SwiftUI `LinearGradient` start/end unit points. Used inside the
/// `GradientPickerScreen` preview strip, the `ModeDetailView` row
/// swatch, and the Previously-Used carousel.
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
