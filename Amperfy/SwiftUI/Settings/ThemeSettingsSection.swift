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
//  PR 20: the inline `ThemeSettingsSection` struct was retired. The
//  Build-38 `.sheet(item:)` + `.confirmationDialog` chain it owned was
//  the root cause of the gradient-picker dismiss cascade (see
//  `DESIGN_REVIEW_RELEASE_4.md` §PR 20). The replacement lives at the
//  top-level Settings root as `CustomThemeRootView`, pushing to
//  `ModeDetailView` per mode and `GradientPickerScreen` per gradient.
//
//  This file now only hosts `FontPickerView`, the shared list picker
//  reused by `CustomThemeRootView`. Kept in this file (rather than
//  spun out) so the Xcode project does not need a file deletion; the
//  file is still referenced from `Amperfy.xcodeproj`.

import AmperfyKit
import SwiftUI
import UIKit

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
