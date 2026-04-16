//
//  InlineFooterRow.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 21 — Settings UI cleanup).
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

// MARK: - InlineFooterRow

/// PR 21: shared descriptor row to replace the janky uppercase `footer:`
/// caption that used to sit outside a `SettingsSection`'s rounded
/// container. Renders as a secondary-styled row INSIDE the same section
/// as the toggle / control it describes, so the whole thing reads as one
/// unified grouped-inset block.
///
/// Used in four sites (Offline Mode, Music Player Skip Buttons,
/// Detailed Information, Disable Player Shuffle Button) at the time of
/// PR 21; additional adopters follow the same pattern.
struct InlineFooterRow: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      // Explicit row insets so the text aligns with the row labels above
      // rather than overflowing to the edge of the grouped-inset card.
      .listRowSeparator(.hidden)
  }
}
