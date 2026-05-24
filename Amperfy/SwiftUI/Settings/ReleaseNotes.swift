//
//  ReleaseNotes.swift
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

import Foundation

// MARK: - ReleaseNote

struct ReleaseNote: Identifiable {
  let id: Int // CURRENT_PROJECT_VERSION
  let date: String // "2026-04-12"
  let title: String // "Build 12 — Playlist folders"
  let whatsNew: [String]
  let testingFocus: [String]
}

// MARK: - ReleaseNotes

enum ReleaseNotes {
  /// Most recent 5 releases, newest first. Updated at ship time.
  static let entries: [ReleaseNote] = [
    ReleaseNote(
      id: 53,
      date: "2026-05-24",
      title: "Build 53 — Related tracks queue actions",
      whatsNew: [
        "Swipe right on a related track to play it immediately",
        "Swipe left on a related track to insert or append to user queue",
        "Existing context menu (three-dot button) with full queue options remains available",
      ],
      testingFocus: [
        "Play a song → open Related Tracks → swipe right on a track: should start playing immediately",
        "Swipe left on a related track: two actions appear (Insert User Queue, Append User Queue)",
        "Insert User Queue: track should appear next in the queue after current song",
        "Append User Queue: track should appear at end of queue",
        "Three-dot menu on each cell still shows full context menu with all options",
        "In offline mode: queue actions should only add cached/available tracks",
      ]
    ),
    ReleaseNote(
      id: 52,
      date: "2026-05-19",
      title: "Build 52 — Cache labels + recent tracks refresh",
      whatsNew: [
        "Fully cached playlists show 'Cached' prefix in their subtitle (visible in both online and offline mode)",
        "Partially cached playlists in offline mode show the cached song count (e.g. '6 cached · 8 Songs · 22m')",
        "Checkmark accessory replaced with the label-based approach for clearer cache status",
        "Empty-name playlist filter removed — names fixed server-side in Navidrome",
        "Recently Added Tracks now supports pull-to-refresh",
      ],
      testingFocus: [
        "Playlists tab (online): fully cached playlist should show 'Cached · N Songs · Xm'",
        "Playlists tab (online): non-cached playlist should show normal subtitle without prefix",
        "Playlists tab (offline): partially cached playlist should show 'N cached · M Songs · Xm'",
        "Playlists tab (offline): fully cached playlist should show 'Cached · M Songs · Xm'",
        "Recently Added Tracks: pull down to refresh after new songs sync",
      ]
    ),
    ReleaseNote(
      id: 50,
      date: "2026-05-18",
      title: "Build 50 — Offline playlist filtering",
      whatsNew: [
        "Playlists with no cached songs are now hidden in offline mode — only playlists with at least one downloaded song appear",
        "Fully cached playlists show a checkmark in the playlist list when offline mode is active",
        "Switching offline mode on/off in Settings immediately updates the playlist list on return",
      ],
      testingFocus: [
        "Enable offline mode → Playlists tab: playlists with zero cached songs should not appear",
        "A playlist with all songs cached should show a checkmark instead of the disclosure arrow",
        "A playlist with some (but not all) songs cached should show the normal disclosure arrow",
        "Disable offline mode → all playlists should reappear, no checkmarks",
        "Toggle offline mode multiple times — the list should update correctly each time",
      ]
    ),
    ReleaseNote(
      id: 47,
      date: "2026-04-17",
      title: "Build 47 — Home screen fix",
      whatsNew: [
        "Fixed a critical bug where empty home screen sections (e.g. Favourite Albums with no favourites) caused section headers to display data from the wrong section",
        "Empty sections in the 'hidden when empty' set (Recently Added Tracks, Favourite Albums, Favourite Artists, Favourite Playlists) now correctly hide without shifting other sections",
        "Tap handling on home screen sections now correctly routes to the right detail view",
      ],
      testingFocus: [
        "Home screen: each section header should match its content — e.g. 'Newest Albums' header shows albums, not genres or tracks",
        "If you have no Favourite Albums/Artists/Playlists, those sections should be completely hidden (no header, no row)",
        "Tapping an album in Newest Albums should open that album's detail view",
        "Tapping a tile in Recently Added Tracks should open the recent tracks detail",
        "Add a favourite album → return to Home → Favourite Albums section should appear with correct content",
      ]
    ),
    ReleaseNote(
      id: 46,
      date: "2026-04-17",
      title: "Build 46 — Theme sharing",
      whatsNew: [
        "Export your custom theme as JSON — copies the full theme configuration to your clipboard for sharing",
        "Import a theme by pasting JSON from your clipboard — applies all colors, gradients, fonts, and borders in one tap",
        "New 'Share' section in Custom Theme settings between Presets and Reset",
      ],
      testingFocus: [
        "Settings → Custom Theme → Share → 'Export Theme': tap and verify 'Copied!' confirmation appears for ~2 seconds, then paste into Notes to verify valid JSON",
        "Copy exported JSON → 'Import Theme': should show confirmation alert → tap Apply → theme should update immediately",
        "Modify the pasted JSON (change a color hex) → import again → verify the changed color applies",
        "Put non-JSON text on clipboard → 'Import Theme' → should show 'Import Failed' error alert",
        "Import with Custom Theme disabled → theme should auto-enable and apply the imported config",
        "Export → Reset to Defaults → Import the exported JSON → original theme should restore",
      ]
    ),
  ]
}
