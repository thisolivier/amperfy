//
//  WhatsNewSettingsView.swift
//  Amperfy
//
//  Created by the Amperfy spike (Feature H — In-app release notes).
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

struct WhatsNewSettingsView: View {
  var body: some View {
    ZStack {
      SettingsList {
        ForEach(ReleaseNotes.entries) { release in
          SettingsSection(
            content: {
              VStack(alignment: .leading, spacing: 12) {
                Text(release.date)
                  .font(.caption)
                  .foregroundColor(.secondary)

                if !release.whatsNew.isEmpty {
                  VStack(alignment: .leading, spacing: 4) {
                    Text("What's New")
                      .font(.subheadline.weight(.semibold))
                    ForEach(release.whatsNew, id: \.self) { bullet in
                      HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                          .foregroundColor(.secondary)
                        Text(bullet)
                          .font(.subheadline)
                      }
                    }
                  }
                }

                if !release.testingFocus.isEmpty {
                  VStack(alignment: .leading, spacing: 4) {
                    Text("Testing Focus")
                      .font(.subheadline.weight(.semibold))
                      .foregroundColor(.orange)
                    ForEach(release.testingFocus, id: \.self) { bullet in
                      HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                          .foregroundColor(.orange)
                        Text(bullet)
                          .font(.subheadline)
                      }
                    }
                  }
                }
              }
              .padding(.vertical, 4)
            },
            header: release.title
          )
        }
      }
    }
    .navigationTitle("What's New")
    .navigationBarTitleDisplayMode(.inline)
  }
}
