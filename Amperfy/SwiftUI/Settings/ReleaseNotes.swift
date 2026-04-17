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
    ReleaseNote(
      id: 44,
      date: "2026-04-17",
      title: "Build 44 — Per-mode typography + album art",
      whatsNew: [
        "Font family is now configured independently for Light Mode and Dark Mode — you can run a serif in dark mode and a sans-serif in light mode",
        "Album art border (width + color) is also per-mode — different border looks for each appearance",
        "Typography and Album Art settings have moved from the Custom Theme root into each mode's detail screen (Light Mode / Dark Mode)",
        "Section headings throughout Settings now sit inside the same rounded section as their content rows, fixing corner-rounding gaps",
        "Presets capture and restore per-mode font and border; old presets migrate automatically",
      ],
      testingFocus: [
        "Settings → Custom Theme → Light Mode → Typography: pick a font (e.g. Georgia) → verify it applies to light mode only; dark mode should still show system or its own font",
        "Settings → Custom Theme → Dark Mode → Album Art: set Border Width 3 pt + bright color → verify dark mode shows border, light mode is unaffected (or has its own setting)",
        "Switch system appearance Light ↔ Dark — fonts and borders should swap to match the mode-specific settings without app restart",
        "Save a preset → load it in a different mode → only that mode's font + border should change",
        "Upgrade from Build 43: existing global font/border should appear in both Light and Dark mode detail screens (migration from legacy keys)",
        "Settings sections with headers (Typography, Album Art, Colors, Gradient, Presets) — the header text should be inside the rounded section rect, not floating above it",
        "Custom Theme root screen should show only: toggle, Light/Dark Mode nav links, Presets, Reset — no font or border controls at root level",
      ]
    ),
    ReleaseNote(
      id: 43,
      date: "2026-04-17",
      title: "Build 43 — Unified background task runner",
      whatsNew: [
        "All three background processes (Album Scan, Playlist Sync, Track Adjacency) now run through a unified serial runner that prevents races and enforces memory budgets",
        "Settings → Library has a new 'Background Tasks' section showing live status, last synced time, and duration for each process",
        "Playlist Sync can be re-enabled via developer settings — it now uses batched Core Data context resets every 5 playlists to prevent the Build 30 memory crash (~2.1 GB Jetsam kill)",
        "Track Adjacency automatically recomputes after a broad playlist sync completes",
        "The runner catches stuck tasks via watchdog timers and recovers interrupted states on app relaunch",
      ],
      testingFocus: [
        "Settings → Library → Background Tasks section: Album Scan and Track Adjacency should show 'Completed X ago (Ys)' after first launch with a connected account",
        "Playlist Sync row shows 'Disabled' by default — enable via Settings → Developer → Phase 2 Playlist Sync toggle, then verify it runs and shows progress",
        "With Phase 2 enabled: monitor memory in Instruments during playlist sync on a large library — should NOT exceed ~500 MB peak (the batched reset discipline)",
        "Force-quit mid-sync and relaunch — interrupted tasks should show 'Failed (interrupted)' in the status panel, then re-run",
        "No buttons or controls in Background Tasks — it's read-only status only",
        "Verify the existing 'Show in Playlists' lazy-sync path still works independently of the runner",
      ]
    ),
    ReleaseNote(
      id: 41,
      date: "2026-04-17",
      title: "Build 41 — Border fix + playlist cleanup",
      whatsNew: [
        "Album art borders now wrap around the rounded corners cleanly, instead of being clipped inside",
        "Composite album art (playlists, smart lists) shows a single border around the whole tile, not four internal borders",
        "Playlist list view is now a cleaner text-only layout without artwork thumbnails",
        "Playlist list content is now aligned with the navigation title and search bar (no extra inset padding)",
      ],
      testingFocus: [
        "Set a border (Settings → Custom Theme → Album Art → Border Width 3pt, bright color) — borders should follow the rounded corners on all album art everywhere",
        "Check playlist art, smart list art, or any 4-tile composite — should show ONE border around the whole tile, not four",
        "Playlists tab — rows should show text only (name + info) without artwork thumbnails",
        "Playlists tab — text content should be aligned to the same left margin as the 'Playlists' title and search bar",
        "Inside a folder — same text-only layout, same alignment",
      ]
    ),
    ReleaseNote(
      id: 40,
      date: "2026-04-16",
      title: "Build 40 — Styling presets",
      whatsNew: [
        "Custom Theme: new Presets section lets you save your current theme configuration as a named snapshot, and reload it later",
        "Presets capture every styling setting: both Light Mode and Dark Mode colors, gradients, font, and album-art border",
        "Three load affordances: load a full preset from the Custom Theme root, or partially apply just the Light or Dark slice from each mode's detail screen",
        "Unnamed presets get a stable auto-label like 'Preset 3'; you can rename or delete any preset at any time",
        "Presets survive Reset to Defaults — your preset library is curated state, not active state",
        "First Release 5 launch auto-saves your current theme as 'My Theme (auto-saved)' so you can always revert",
      ],
      testingFocus: [
        "Settings → Custom Theme → modify some colors + font → tap 'Save Current as Preset' → name it 'Sunset' → row appears in Presets list",
        "Save another preset with the name field left empty — it should appear as 'Preset 1' (or next integer)",
        "Reset to Defaults should NOT delete any presets — the list survives across resets",
        "Light Mode → 'Load From Preset' → pick a preset → only light-mode colors + light gradient change; dark mode, font, and border stay put",
        "Long-press a preset row → Rename / Delete should work; swipe trailing should also offer Delete",
        "Kill the app and relaunch — all saved presets should still be there",
        "Upgrading from Build 39 with a configured custom theme should automatically add one preset named 'My Theme (auto-saved)'",
      ]
    ),
  ]
}
