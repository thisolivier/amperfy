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
      id: 28,
      date: "2026-04-12",
      title: "Build 28 — Launch crash fix",
      whatsNew: [
        "CRITICAL: Fixed launch crash caused by theme + adjacency engine interaction",
        "Removed UIView.appearance().tintColor (interfered with system views)",
        "Replaced unsafe window subview remove/re-add with safe setNeedsLayout",
        "Tint color now applied via targeted proxies and window-level property",
        "Both custom theme and Track Adjacency Engine re-enabled",
      ],
      testingFocus: [
        "Launch the app — should not crash or freeze",
        "Enable custom theme — verify tint color applies to nav bar, tab bar, buttons",
        "Related Tracks should still work",
        "Toggle theme on/off — no crash, colors update correctly",
        "Switch accounts — no crash during theme re-application",
      ]
    ),
    ReleaseNote(
      id: 27,
      date: "2026-04-12",
      title: "Build 27 — DIAGNOSTIC: Adjacency only",
      whatsNew: [
        "DIAGNOSTIC BUILD: Track Adjacency Engine ONLY — Custom theme fully disabled",
        "ThemeStore.isEnabled forced to false — all theme colors use system defaults",
        "Track adjacency computation active on launch and after sync",
        "\"Related Tracks\" menu item active",
        "If this build crashes, the cause is the ADJACENCY ENGINE",
      ],
      testingFocus: [
        "Launch the app — does it crash within 30 seconds?",
        "Navigate all tabs — is the app stable?",
        "Custom theme toggle should have no effect (disabled at code level)",
        "Compare with Build 26 (theme only) to isolate the crash source",
      ]
    ),
    ReleaseNote(
      id: 26,
      date: "2026-04-12",
      title: "Build 26 — DIAGNOSTIC: Theme only",
      whatsNew: [
        "DIAGNOSTIC BUILD: Theme changes ONLY — Track Adjacency Engine fully disabled",
        "Custom theme, lifecycle observers, and color helpers are all active",
        "Track adjacency computation disabled on launch and after sync",
        "\"Related Tracks\" menu item hidden",
        "If this build crashes, the cause is the THEME changes",
      ],
      testingFocus: [
        "Launch the app — does it crash within 30 seconds?",
        "Navigate all tabs — is the app stable?",
        "Toggle custom theme on/off — any crash?",
        "Compare with Build 27 (adjacency only) to isolate the crash source",
      ]
    ),
    ReleaseNote(
      id: 25,
      date: "2026-04-12",
      title: "Build 25 — Launch crash fix",
      whatsNew: [
        "CRITICAL: Fixed launch crash caused by track adjacency computation blocking the main thread",
        "Adjacency computation now uses a dedicated background Core Data context",
      ],
      testingFocus: [
        "Launch the app — should not crash or freeze",
        "Related Tracks should still work after launch",
        "Verify no UI freezes during the first 30 seconds after launch",
      ]
    ),
    ReleaseNote(
      id: 24,
      date: "2026-04-12",
      title: "Build 24 — Track Adjacency bug fixes",
      whatsNew: [
        "Fixed: \"Show Album\" from Related Tracks no longer traps in the modal (navigates on main stack)",
        "Fixed: Source info (\"In N playlists nearby\" / \"Same album\") now displays on related track rows",
        "Fixed: Launch-time adjacency computation skipped on first install (no empty JSON race)",
        "Adjacency store rejects empty cached data and recomputes automatically",
        "Playlist sync now invalidates adjacency cache so next computation picks up new data",
        "Note: On first install, Related Tracks may require browsing a playlist before data appears",
      ],
      testingFocus: [
        "Open Related Tracks → tap … on a row → Show Album — should navigate on the main screen, not inside the modal",
        "Related track rows should show source info text below artist name",
        "Fresh install: browse a playlist, then check Related Tracks — should show results",
        "Kill and relaunch after browsing playlists — Related Tracks should load instantly",
        "Verify Related Tracks still works on non-fresh installs as before",
      ]
    ),
    ReleaseNote(
      id: 23,
      date: "2026-04-12",
      title: "Build 23 — Track Adjacency Engine",
      whatsNew: [
        "NEW: Track Adjacency Engine — analyzes playlist sequencing to find related tracks",
        "NEW: \"Related Tracks\" in song context menu — shows top 20 tracks that frequently appear near the selected song across your playlists",
        "Computes similarity from playlist adjacency (±1/±2 position), co-membership, and album membership",
        "Computation runs in background on launch, persists to disk",
        "Source info shows \"In N playlists nearby\" or \"Same album\"",
      ],
      testingFocus: [
        "Open a song's … menu that appears in multiple playlists — \"Related Tracks\" should appear",
        "Tap \"Related Tracks\" — verify the list shows up to 20 songs with title, artist, and album art",
        "Verify source info text (\"In N playlists nearby\" or \"Same album\") is shown",
        "Tap a related track — it should start playing",
        "Try the … menu on a related track row — standard song actions should appear",
        "Songs not in any playlist should NOT show \"Related Tracks\" in their menu",
        "Kill and relaunch — Related Tracks should still work (persisted to disk)",
      ]
    ),
    ReleaseNote(
      id: 22,
      date: "2026-04-12",
      title: "Build 22 — Theme lifecycle fix",
      whatsNew: [
        "Theme lifecycle fix: Library and Home tabs update colors immediately when theme is toggled",
        "Home section headers and carousel album/artist labels refresh on theme change",
        "Library row labels and icons refresh on theme change",
        "No app restart needed after enabling or changing custom theme",
      ],
      testingFocus: [
        "Open app fresh — navigate to Home and Library tabs first",
        "Go to Settings → Display & Interaction → enable Custom Theme with a distinct color",
        "Switch back to Home tab — section headers and album labels should be themed immediately",
        "Switch to Library tab — row labels and icons should be themed immediately",
        "Toggle theme off — colors should revert to defaults without restart",
      ]
    ),
    ReleaseNote(
      id: 21,
      date: "2026-04-12",
      title: "Build 21 — Feature sweep polish",
      whatsNew: [
        "\"NEW\" badge on What's New row in Settings (clears when viewed)",
        "\"Show in Playlists\" loads instantly with a spinner instead of blocking",
        "Share Song temp file cleaned up after share sheet dismisses",
        "Renamed \"In Playlists\" to \"Show in Playlists\" (Apple convention)",
        "Selection count (\"N selected\") in playlist folders edit mode action bar",
      ],
      testingFocus: [
        "Install build — Settings should show a NEW badge on What's New; tap it, badge should clear",
        "Long-press a song → Show in Playlists — sheet should appear immediately with a spinner on first use",
        "Share a song — verify no leftover temp files accumulate",
        "Context menu should say \"Show in Playlists\", not \"In Playlists\"",
        "Playlist folders: tap Edit, select items — \"N selected\" label should update live",
      ]
    ),
    ReleaseNote(
      id: 20,
      date: "2026-04-12",
      title: "Build 20 — Full theme coverage + In Playlists fix",
      whatsNew: [
        "Theme coverage round 2: all screens now fully themed (backgrounds, text, tint)",
        "Library row labels and icons pick up custom text and tint colors",
        "Albums grid cell labels (title + artist) now themed",
        "Song artist subtitles use themed secondary text color",
        "Background themed on all screens including album detail header and empty states",
        "Tint color reaches tab bar icons, nav chevrons, Play/Shuffle buttons",
        "'In Playlists' no longer shows auto-generated playlists with empty names",
      ],
      testingFocus: [
        "Enable custom theme — every screen should have consistent background, text, and tint",
        "Library tab: row labels and SF Symbol icons should use custom colors",
        "Albums grid: album titles and artist names should be themed",
        "Album detail: header area (art + metadata) should have themed background",
        "Navigate to a page with no content — background should be themed, not white",
        "Tab bar icons, back chevrons, Play/Shuffle buttons should use tint color",
        "Long-press a song → In Playlists — should not show nameless/duplicate entries",
      ]
    ),
    ReleaseNote(
      id: 19,
      date: "2026-04-12",
      title: "Build 19 — Theme coverage fixes",
      whatsNew: [
        "Extended theme background color to all screens (was only Albums grid)",
        "Themed cell body text (row labels, song titles) with custom text color",
        "Mini-player controls now use tint color",
        "Full player controls use tint color (was incorrectly using text color)",
        "Folder SF Symbol icons pick up theme tint",
        "Section headers and disclosure chevrons themed",
      ],
      testingFocus: [
        "Enable custom theme — visit every tab and screen, background color should be consistent everywhere",
        "Check row labels and song titles use the custom text color, not default black/white",
        "Mini-player: play/pause and skip buttons should use tint color",
        "Full player: all control buttons should use tint color, not text color",
        "Playlist folders: folder icons should match tint color",
        "Section headers and chevron arrows should pick up theme colors",
      ]
    ),
    ReleaseNote(
      id: 16,
      date: "2026-04-12",
      title: "Build 16 — Playlist folders v2 + theme polish",
      whatsNew: [
        "Playlist folders: single unified view (no flat/folder toggle), always-on search and sort",
        "Playlist folders: custom floating action bar for multi-select (fixes toolbar/tab bar overlap)",
        "Custom theme now covers all major surfaces: backgrounds, nav bar, tab bar, search bar, mini-player, full player",
        "Home section title alignment fixed (was double-padded)",
        "Shared songs renamed to 'Title - Artist.ext' for a friendly filename",
        "Library tab: 'Albums' (unfiltered) and 'Complete Albums' (whole-album predicate) as separate entries",
      ],
      testingFocus: [
        "Try custom theme on all screens — backgrounds, text, controls should all use custom colors",
        "Playlist folders: tap Edit, select playlists — floating action bar should appear above the tab bar",
        "Playlist folders: search and sort should work at all levels without toggling",
        "Library tab: verify 'Albums' shows everything, 'Complete Albums' filters singles",
        "Share a song — filename should be 'Song - Artist.ext' in the share sheet",
      ]
    ),
    ReleaseNote(
      id: 15,
      date: "2026-04-12",
      title: "Build 15 — remoteSongCount re-sync",
      whatsNew: [
        "Fixed: albums with stale remoteSongCount=0 are now re-synced in the background",
        "Fixes albums missing from 'Newest Albums' and tracks incorrectly appearing in 'Recently Added Tracks'",
      ],
      testingFocus: [
        "Check Home tab 'Newest Albums' — verify all expected albums appear",
        "Check 'Recently Added Tracks' — should not show tracks from full albums",
        "Kill and relaunch — background sync should fix any remaining stale albums",
      ]
    ),
    ReleaseNote(
      id: 14,
      date: "2026-04-12",
      title: "Build 14 — Custom Theme",
      whatsNew: [
        "New 'Custom Theme' toggle in Settings > Display & Interaction",
        "Independent color pickers for light and dark mode (background, text, tint)",
        "Custom font family picker with all system fonts and Dynamic Type support",
        "Contrast warning shown when text/background colors are too similar",
        "Reset to Defaults clears all customizations",
        "Theme persists across app launches",
      ],
      testingFocus: [
        "Toggle Custom Theme ON — swatches should match current stock colors",
        "Pick a background color — verify it applies to nav bar, tab bar, and table views",
        "Pick a text color — verify labels update across Home, Albums, Player",
        "Pick a tint color — verify buttons, tab bar icons, and interactive elements change",
        "Switch between light and dark mode — each should use its own color set",
        "Select a custom font — confirm Dynamic Type sizes are preserved",
        "Reset to Defaults — confirm stock appearance is fully restored",
        "Kill and relaunch — custom colors should apply on launch with no flash",
      ]
    ),
    ReleaseNote(
      id: 13,
      date: "2026-04-12",
      title: "Build 13 — Playlist folder UX fixes",
      whatsNew: [
        "Flat View is now an in-place toggle (no more pushing a separate screen)",
        "Flat View includes search and sort options (name, last played, change date, duration)",
        "Edit mode with multi-select works at all levels (root + inside folders)",
        "Inside a folder, toolbar shows 'Remove from Folder' instead of 'Add to Folder'",
        "Context menu no longer shows irrelevant 'Add to Folder' for playlists already in a folder",
        "New Folder option available inside subfolders",
      ],
      testingFocus: [
        "Toggle Flat View on/off from the … menu — should switch in place, not push",
        "In Flat View, use search bar and try each sort option",
        "Tap Edit at root — multi-select playlists, tap 'Add to Folder'",
        "Tap Edit inside a folder — multi-select, tap 'Remove from Folder'",
        "Long-press a playlist inside a folder — should NOT show 'Add to Folder'",
      ]
    ),
    ReleaseNote(
      id: 12,
      date: "2026-04-12",
      title: "Build 12 — Playlist folders",
      whatsNew: [
        "Organize playlists into folders (Playlists tab)",
        "Multi-select + batch 'Add to Folder'",
        "Playlists can appear in multiple folders",
        "Nested subfolders supported",
        "Context menus on folders (Rename, Delete) and playlists (Add/Move/Remove)",
        "'Flat View' fallback accessible from nav bar menu",
      ],
      testingFocus: [
        "Create a folder, add playlists — verify they disappear from root",
        "Add a playlist to two folders — confirm it shows in both",
        "Delete a folder — playlists should return to root",
        "Kill + relaunch — folder structure persists",
        "Long-press a playlist for context menu, try each action",
      ]
    ),
    ReleaseNote(
      id: 11,
      date: "2026-04-11",
      title: "Build 11 — In Playlists sync fix",
      whatsNew: [
        "Fixed: 'In Playlists' now shows all playlists containing a song, not just recently opened ones",
        "First tap syncs playlist items from server (one-time cost per playlist)",
        "Subsequent taps are instant",
      ],
      testingFocus: [
        "Long-press a song → 'In Playlists' — should list ALL playlists containing it",
        "First tap may show a brief 'Syncing playlists...' progress indicator",
        "Second tap on same action should be instant",
      ]
    ),
    ReleaseNote(
      id: 10,
      date: "2026-04-11",
      title: "Build 10 — Albums performance",
      whatsNew: [
        "Fixed off-by-one crash in Albums section index",
        "Albums section index titles now cached (faster scrolling)",
        "Reconfigure scan short-circuited when no objects changed",
        "Play/Shuffle prefetches album songs in batch (eliminates fault storms)",
      ],
      testingFocus: [
        "Scroll through Albums tab quickly using the side index",
        "Tap Play or Shuffle on an album — should start without delay",
        "Switch between Albums tab and other tabs repeatedly",
      ]
    ),
    ReleaseNote(
      id: 9,
      date: "2026-04-11",
      title: "Build 9 — Share a song",
      whatsNew: [
        "Share a song via iOS share sheet (long-press → Share)",
        "Downloads the song if not cached, then shares the audio file",
        "Downloaded file also added to offline library",
      ],
      testingFocus: [
        "Long-press a song → Share → send via Messages or AirDrop",
        "Try sharing a song that is not yet downloaded",
        "Try sharing a song that is already cached",
      ]
    ),
    ReleaseNote(
      id: 8,
      date: "2026-04-11",
      title: "Build 8 — Favourites on Home",
      whatsNew: [
        "Favourite Albums, Artists, and Playlists sections on the Home tab",
        "Pin/unpin playlists via heart toggle in playlist detail view",
        "Sections hidden when empty",
        "Favourites ignore the 'Complete Albums Only' filter",
      ],
      testingFocus: [
        "Favourite an album/artist — confirm it appears in the Home tab section",
        "Unfavourite — confirm it disappears from Home",
        "Pin a playlist via the heart icon in playlist detail",
        "Verify pinned playlists appear on Home, unpinned ones don't",
      ]
    ),
  ]
}
