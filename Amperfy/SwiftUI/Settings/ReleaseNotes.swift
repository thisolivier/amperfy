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
      id: 39,
      date: "2026-04-15",
      title: "Build 39 — Album art borders + theme polish",
      whatsNew: [
        "Custom Theme: new 'Album Art' section adds an optional border (0–6 pt, any color) around all album artwork, including the 4-tile composites used for playlists and smart lists",
        "Settings → Custom Theme is now a top-level row, no longer buried inside Display & Interaction",
        "Custom Theme screen restructured: Light Mode and Dark Mode are now NavigationLink-pushed detail screens, and Gradient editing is its own screen with Start / End colors, a live preview strip, a direction picker, and a Previously Used carousel",
        "Gradients are now 2-stop only (start colour, end colour); any saved 3- or 4-stop gradients are automatically reduced to their first and last colour on load",
        "Fixed: the gradient picker no longer collapses the whole Settings sheet when any swatch is tapped",
        "Settings modal now renders on top of your custom gradient / solid theme background (previously broke out into system grey at the modal edge)",
        "Library tab now picks up the active gradient / solid theme background; cell backgrounds are transparent while any custom theme is active",
        "Footer descriptor strings (Offline Mode, Haptic Feedback, Music Player Skip Buttons, Detailed Information, Disable Player Shuffle Button) are now inlined as secondary rows inside their parent section, instead of free-floating uppercase captions",
      ],
      testingFocus: [
        "Settings → Custom Theme should now appear as a top-level Settings row (with a paint-palette icon), above Account",
        "Settings → Custom Theme → Album Art → set Border Width to 3 pt and pick a bright colour — every album cover in Albums grid, Playlists, Home carousels, and the 4-tile composite should show that border, in both single and composite art",
        "Set Border Width to 0 — borders should disappear everywhere",
        "Now Playing screen: the album art should NOT have the border (by design — only browse surfaces are affected)",
        "Settings → Custom Theme → Light Mode → tap Gradient → pick Start + End colours → adjust Direction — the Settings modal itself, Home, Library, and album detail should all preview the gradient live without dismissing back to Settings root",
        "From the Gradient picker, tap a swatch in Previously Used — it should apply immediately without popping the screen",
        "Tap 'Clear Gradient' inside the gradient picker — gradient should be removed and the solid background colour should return",
        "Flip the system between Light and Dark at OS level — gradients and borders should swap to the mode-specific choices and repaint without app restart",
        "Upgrade from Build 38 with a saved 3- or 4-stop gradient — on first launch it should render as a 2-stop gradient using the original first and last colours",
        "Settings root: the Offline Mode description should now sit directly under the toggle inside the same rounded section, not as a floating uppercase caption below",
        "Settings → Display & Interaction: Haptic Feedback, Music Player Skip Buttons, Detailed Information, and Disable Player Shuffle Button descriptors should all sit inside their respective sections",
        "Library tab with a gradient active: the gradient should flow behind the library list; individual rows should not paint their own grey background over the gradient",
        "Settings → Reset to Defaults → confirm — border width + colour should clear along with the rest of the custom theme state; any saved gradients and history should NOT be reset (kept intentionally)",
      ]
    ),
    ReleaseNote(
      id: 38,
      date: "2026-04-15",
      title: "Build 38 — Custom background gradients",
      whatsNew: [
        "Custom Theme: new 'Background Gradient' section lets you pick a multi-color gradient as the app background, independently for Light and Dark mode",
        "Gradient editor supports 2–4 color stops, six directions, and a live preview before you commit",
        "Previously Used gradient carousel keeps up to 20 of your recent designs — tap any swatch to reuse it for Light or Dark mode",
        "Reset to Defaults now clears the active gradient selection but keeps your gradient history intact",
      ],
      testingFocus: [
        "Settings → Custom Theme → toggle ON → 'Background Gradient' section should appear with rows for Light and Dark mode",
        "Tap 'Light Mode Gradient' → editor sheet opens → pick two colors, adjust direction, tap 'Apply & Save' — Home tab background should adopt the gradient",
        "In the editor, tap 'Add Color' up to 4 times; tap the minus on any row to remove (minimum 2 colors enforced)",
        "Switch Light/Dark mode at the system level — the background should swap between your two gradient choices (or fall back to the solid background color for any mode without a gradient)",
        "Tap a swatch under 'Previously Used' → action sheet prompts Light Mode / Dark Mode / Cancel → verify the chosen slot updates",
        "Tap the × on the Light or Dark gradient row to clear it — the solid background color should return for that mode",
        "Album detail screen should also render the gradient behind the track list; cell backgrounds should stay transparent while any gradient is active",
        "Settings → Reset to Defaults → confirm — both gradients clear AND custom theme toggle goes off, but the Previously Used carousel should still list your earlier gradients",
        "Quit and relaunch — gradient selection should persist through restarts",
      ]
    ),
    ReleaseNote(
      id: 37,
      date: "2026-04-15",
      title: "Build 37 — Delete playlist folders",
      whatsNew: [
        "Delete playlist folders. Swipe left on any folder (or use edit mode) to delete it. The playlists and sub-folders inside pop up one level — nothing inside the folder is lost",
      ],
      testingFocus: [
        "Playlists tab → long-left-swipe on a folder row → red 'Delete' button appears → tap it → confirmation alert appears (unless folder is empty)",
        "Playlists tab → … menu → 'Select Items' → red minus circle appears on folder rows — tap it, then tap 'Delete' on the right → same confirmation",
        "Long-press a folder → 'Delete Folder' still works from context menu",
        "Confirmation copy: for folder 'Rock' with 3 playlists and 1 subfolder, reads 'Delete folder \\'Rock\\'? The 3 playlists and 1 sub-folder inside will move to the parent level.' Singular/plural should be correct",
        "Create an empty folder, swipe-delete it — should vanish immediately with no alert",
        "Set up: root folder 'Rock' with playlists A, B and subfolder 'Metal' (containing C). Delete 'Rock'. Verify A, B, and 'Metal' are now at root; C still inside 'Metal'",
        "Nested: folder 'Music' contains 'Rock' which contains playlist A and subfolder 'Metal'. Delete 'Rock'. Verify 'Music' now contains 'Metal' + A; 'Metal' still contains its own playlist",
        "After any delete, tap each surviving playlist — it should open and play normally (no playlists were lost)",
        "Start a delete, tap 'Cancel' — folder and contents unchanged",
        "Offline mode: toggle on, delete a folder — should still work (local-only operation)",
      ]
    ),
    ReleaseNote(
      id: 36,
      date: "2026-04-15",
      title: "Build 36 — Whole-album randomizer + heading theme tier",
      whatsNew: [
        "Home 'Random Albums' and CarPlay Play Random now serve whole albums only (min 3 tracks) and weight albums with mostly-unplayed tracks 2× higher",
        "Custom Theme: new 'Heading Color' row per mode separates heading text from body text; existing installs migrate their old text color into both tiers",
        "Custom Theme: selected font family now flows through Home section headers and album/artist/playlist detail titles",
        "Contrast warning in Settings now checks heading and body colors against the background independently",
      ],
      testingFocus: [
        "Home tab → pull to refresh 'Random Albums' a few times: all entries should be full albums (3+ tracks), no singles/EPs, with visible variety",
        "Play a handful of tracks on one album, refresh Random Albums repeatedly — the unplayed album should show up notably more often than the fully-played one",
        "CarPlay → Play Random should likewise surface only whole albums",
        "Settings → Custom Theme: toggle ON — 'Heading Color' and 'Body Color' rows should appear under each mode",
        "Pick a distinct heading color vs body color — Home section headers, nav bar titles, and album detail title should use heading color; table/collection cell labels should use body color",
        "Pick a custom font — Home section headers and album/artist detail title should adopt the font (weight may look lighter, that is expected)",
        "Set heading color very close to background — a 'low heading/background contrast' warning should appear; set body too close — a separate 'low body/background contrast' warning should appear",
        "Upgrade from Build 35 with a custom text color already set — heading and body should both adopt that color on first launch (no default-label regression)",
        "Settings → Reset to Defaults → confirm — both heading and body colors should clear",
      ]
    ),
    ReleaseNote(
      id: 35,
      date: "2026-04-14",
      title: "Build 35 — Playlist page UX simplify",
      whatsNew: [
        "Playlists tab: merged Edit button into the … menu as 'Select Items' — single top-level control",
        "Nav bar now shows only one button (…) instead of two, reducing visual clutter",
        "Select Items toggles to 'Done' when in edit mode",
      ],
      testingFocus: [
        "Playlists tab → tap … menu — 'Select Items', 'New Folder', and 'Sort' should all appear",
        "Tap 'Select Items' → multi-select mode activates with floating action bar",
        "Tap … menu again → should show 'Done' instead of 'Select Items'",
        "Tap 'Done' → exits edit mode normally",
        "Verify New Folder and Sort still work from the … menu",
      ]
    ),
    ReleaseNote(
      id: 34,
      date: "2026-04-14",
      title: "Build 34 — Menu cleanup",
      whatsNew: [
        "Album detail: removed redundant Play, Shuffle, and Show Artist from the … menu (already available as buttons)",
        "Playlist detail: removed redundant Play and Shuffle from the … menu",
        "Playlist detail: moved Edit and Favourite actions into the … menu for a cleaner toolbar",
        "Added backlog items: Offline Downloaded Albums (PR 13), Offline Complete Title (PR 14), Offline Playlist Filter (PR 15)",
      ],
      testingFocus: [
        "Open an album → tap … menu — Play, Shuffle, and Show Artist should NOT appear",
        "Open a playlist → tap … menu — Play and Shuffle should NOT appear; Edit and Favourite SHOULD appear",
        "Verify Play and Shuffle still work via the header buttons on both album and playlist detail",
        "Long-press a playlist → context menu should still work as before",
      ]
    ),
    ReleaseNote(
      id: 33,
      date: "2026-04-14",
      title: "Build 33 — Adjacency Engine v2",
      whatsNew: [
        "Rebuilt Track Adjacency Engine with SQLite storage (replaces crash-prone in-memory JSON)",
        "Fixed Jetsam memory kill on launch — peak memory down from 154 MB+ crash to ~100 MB",
        "Windowed O(n×W) algorithm caps pair generation per playlist (W=10)",
        "Protocol-separated architecture (compute/storage/query) for maintainability",
        "Second launch is instant — SQLite cached, no recomputation needed",
      ],
      testingFocus: [
        "Launch the app — should not crash (was crashing within 20s on Build 32 for large libraries)",
        "Related Tracks should still work — open a song's … menu and tap Related Tracks",
        "Kill and relaunch — Related Tracks should load instantly without recomputation",
        "Browse library, play music — verify no memory-related crashes during normal use",
      ]
    ),
    ReleaseNote(
      id: 32,
      date: "2026-04-13",
      title: "Build 32 — Memory crash hotfix",
      whatsNew: [
        "CRITICAL: Fixed Jetsam memory kill (~2.1 GB) that crashed the app within 20s of launch",
        "Temporarily disabled background playlist item sync — root cause of unbounded memory growth",
        "Added memory diagnostics instrumentation for future profiling",
        "Removed unnecessary Task.detached wrapper in Related Tracks",
      ],
      testingFocus: [
        "Launch the app — should stay open indefinitely without crashing",
        "Browse library, play music, check all tabs work normally",
        "Related Tracks will show 'no related tracks' until playlist sync is re-enabled with batching",
      ]
    ),
    ReleaseNote(
      id: 30,
      date: "2026-04-13",
      title: "Build 30 — Font fix + design sweep polish",
      whatsNew: [
        "Fixed: Custom font selection now actually applies to nav bar titles, large titles, and section headers",
        "Fixed: Font picker preview shows the correct font (was showing system font for most entries)",
        "Related Tracks loads asynchronously with a spinner (no more UI freeze on large libraries)",
        "Show in Playlists has a 30-second timeout (no more infinite spinner if server is slow)",
        "Empty state added for Recently Added Tracks when no qualifying songs exist",
        "Fixed constraint accumulation in Recently Added Tracks header on scroll",
        "Cleaned up dead code in Track Adjacency Engine album bonus logic",
        "Removed diagnostic builds (26, 27) from release notes",
      ],
      testingFocus: [
        "Enable Custom Theme, pick a font — nav bar titles and section headers should change",
        "Font picker: each row should preview in its actual font, not system font",
        "Open Related Tracks on a song in many playlists — should show spinner, then results (no freeze)",
        "Show in Playlists with airplane mode — should timeout after ~30s, not spin forever",
        "Recently Added Tracks with no qualifying songs — should show empty state message",
        "Scroll the Recently Added Tracks header off and on screen repeatedly — no layout glitches",
      ]
    ),
    ReleaseNote(
      id: 29,
      date: "2026-04-12",
      title: "Build 29 — Auto-fetch playlists + stale score fix",
      whatsNew: [
        "Playlist items are now automatically fetched in the background on launch",
        "Related Tracks works without manually browsing each playlist first",
        "Stale adjacency scores remain readable during background recomputation (no blank window)",
        "Adjacency scores persist across launches and work offline",
        "Background sync: albums first, then playlist items, then adjacency recomputation",
      ],
      testingFocus: [
        "Fresh install: launch app, wait for background sync — Related Tracks should populate automatically",
        "Kill and relaunch offline — Related Tracks should still show results from cached data",
        "While background sync is running, open Related Tracks — should show stale data, not empty",
        "After sync completes, Related Tracks should reflect updated playlist data",
        "Verify no UI freezes during background playlist sync",
      ]
    ),
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
    // Builds 26 & 27 were diagnostic-only builds (theme/adjacency isolation)
    // — removed from user-facing release notes.
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
