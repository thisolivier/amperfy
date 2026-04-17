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
  ]
}
