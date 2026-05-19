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
      id: 51,
      date: "2026-05-18",
      title: "Build 51 — Playlist cleanup + recent tracks refresh",
      whatsNew: [
        "Playlists with empty names (auto-synced from .m3u files on the server) are now hidden from the playlist list",
        "Recently Added Tracks now supports pull-to-refresh — pull down to reload after new songs are synced",
      ],
      testingFocus: [
        "Playlists tab: no unnamed/blank playlists should appear",
        "Recently Added Tracks: pull down to refresh — new songs should appear without leaving the view",
        "Recently Added Tracks: song names and artist names should be correct after a sync",
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
    ReleaseNote(
      id: 45,
      date: "2026-04-17",
      title: "Build 45 — Playlist sync enabled",
      whatsNew: [
        "Playlist background sync is now enabled by default — playlist items sync automatically on launch alongside album scan and adjacency compute",
        "Memory safety: playlist items are parsed in a dedicated async context (per-playlist bounded), and the main context resets every 5 playlists to prevent accumulated faults",
        "Track adjacency automatically recomputes after playlist sync completes, so adjacency scores reflect the latest playlist data",
      ],
      testingFocus: [
        "Settings → Library → Background Tasks: 'Playlist Sync' should now show progress or 'Completed' instead of 'Disabled'",
        "On first launch with this build: all three background tasks (Album Scan, Playlist Sync, Adjacency) should run sequentially",
        "Monitor memory in Instruments during playlist sync on a large library — peak should stay under ~500 MB",
        "Force-quit mid-sync and relaunch — interrupted tasks should recover and re-run",
        "After playlist sync completes, adjacency should automatically start computing",
      ]
    ),
  ]
}
