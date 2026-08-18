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
      id: 84,
      date: "2026-08-18",
      title: "Build 84 — Smart Playlists: groups, and/or, complete albums",
      whatsNew: [
        "Smart playlist rules can now be combined with 'and' OR 'or', and grouped one level deep — so queries like 'added recently AND (never played OR in fewer than 2 playlists)' are expressible. Tap the connector chip between rules to flip a level between and/or; groups carry their own chips.",
        "New rule: 'Part of a complete album' / 'Not part of a complete album' — using the same definition as the Albums view's complete-albums toggle (not a single, at least 3 tracks on the server).",
        "Your existing smart playlist query and its frozen results carry over unchanged.",
        "Refresh now also catches new songs added to albums you already had — previously an old album gaining new tracks could be invisible to 'added in the last X days'.",
      ],
      testingFocus: [
        "Build a grouped query: add a rule, then + Add Group with two rules inside, and set the group to 'or' via its chip or ⋯ menu. Run it and sanity-check the results.",
        "Tap an and/or chip between top-level rules — every chip at that level should flip together; the group's own chip should not move.",
        "Add 'Not part of a complete album' to a query and confirm the results are loose tracks and singles, not full albums.",
        "If you had a query from the last build, open Smart Playlists first thing and confirm it loaded intact without refreshing.",
      ]
    ),
    ReleaseNote(
      id: 83,
      date: "2026-08-17",
      title: "Build 83 — Smart Playlists",
      whatsNew: [
        "New in Library: Smart Playlists. Build a query from stackable rules — added in the last X days, never played (or not played in the last X days), in fewer or more than N playlists, and in / not in a specific playlist — and get back a playable track list.",
        "The result is a frozen snapshot: it survives app restarts and never changes behind your back. When you want it brought up to date, tap the Refresh button under the artwork — nothing updates until you do.",
        "Results play like any playlist: tap a song to start there, skip forward and back through the query results, shuffle the lot.",
        "Refreshing online also backfills recently added albums from the server, so 'added in the last X days' catches music that arrived via other apps.",
        "Play counts from the server now merge into the app, and plays you make offline still count immediately — so 'never played' respects both your other devices and your bus rides.",
        "Playlists can now be deleted from the ⋯ menu on the playlist's own page, with a confirmation step.",
      ],
      testingFocus: [
        "Library → Smart Playlists: build 'Added within 90 days' + 'Never played', run it, and sanity-check the results against what you know is new.",
        "Play a track from a never-played query, then tap Refresh — the track you just played should drop out of the results.",
        "Force-quit the app and come back: the result list and its 'Refreshed' time should be exactly as you left them.",
        "Add a 'Not in playlist …' rule pointing at a playlist you use, refresh, and confirm none of its songs appear.",
        "Open a playlist, tap ⋯ → Delete Playlist, confirm, and check it's gone on your other devices too.",
      ]
    ),
    ReleaseNote(
      id: 82,
      date: "2026-08-04",
      title: "Build 82 — Folder fixes: offline folders, remove vs delete",
      whatsNew: [
        "Fixed: after a full resync, Show in Playlists could confidently tell you a song wasn't in any playlist when it actually was. The app was trusting a stale record of what it had already synced, so playlist contents were never re-downloaded.",
        "Folders you create on a slow or offline connection are now fully editable straight away. You can rename them, file playlists into them and keep working while the folder finishes syncing, and if you're inside one when it syncs, the screen follows it rather than emptying out.",
        "In folder browsing, Delete now means remove from this folder. The Delete key, swiping, and the bulk actions all take the playlist out of the folder and leave it untouched in your library. Deleting a playlist from your library for good is still only on the playlist's own page.",
      ],
      testingFocus: [
        "Turn on airplane mode, create a folder and file some playlists into it, then reconnect. Confirm the folder uploads with its contents intact and stays editable throughout.",
        "While browsing inside a folder, remove a playlist with the Delete key, a swipe, and a bulk action. Confirm each takes it out of the folder but the playlist is still in your library.",
        "Do a full resync from Settings, then use Show in Playlists on a song you know is filed in a playlist. Confirm it lists the playlist instead of showing nothing.",
      ]
    ),
    ReleaseNote(
      id: 81,
      date: "2026-08-04",
      title: "Build 81 — Bulk playlist organization",
      whatsNew: [
        "Folders and playlists now appear together in a single list, in the order you arranged them, instead of being split into separate sections.",
        "You can select several items at once and act on them together. On Mac, ⌘-click to pick out individual rows and ⇧-click to select a range.",
        "Drag items onto a folder to file them away, or drop them between rows to reorder. Holding a drag over a folder opens it so you can file things deeper in.",
        "Bulk actions are available from the toolbar or by right-clicking: Move to Folder, Add to Folder, Remove from This Folder, and New Folder from Selection.",
        "Keyboard shortcuts work throughout: arrow keys to move around, ⌘A to select all, ⌘N for a new folder, ⌘M to move, return to rename, and ⌫ to delete. Mac also gets a new Organize menu.",
        "Your folder organization now syncs with the server and keeps the manual order you set, and every change is backed up to a JSON file you can see in the Files app.",
        "Fixed: folder changes could silently fail depending on how the server formatted folder IDs, and folders you created while offline could go missing. Both now work correctly.",
      ],
      testingFocus: [
        "Select several playlists and folders at once, then use Move to Folder from the toolbar. Confirm they all land where you expect and are still there after you reopen the app.",
        "Drag a playlist onto a folder, then drag rows around to reorder them. Reopen the app and confirm your order was kept.",
        "Create a folder while offline, then reconnect and confirm it survives and shows up on your other devices.",
      ]
    ),
    ReleaseNote(
      id: 80,
      date: "2026-07-17",
      title: "Build 80 — Rename playlists",
      whatsNew: [
        "You can now rename a playlist right from the main Playlists screen: long-press it and choose Rename. The new name saves immediately and syncs to your other devices.",
      ],
      testingFocus: [
        "Long-press a playlist on the Playlists screen, choose Rename, type a new name, and confirm it updates — and that it stays renamed after you reopen the app.",
        "Try renaming a playlist that lives inside a folder; confirm it keeps its new name and stays in the folder.",
      ]
    ),
    ReleaseNote(
      id: 79,
      date: "2026-07-17",
      title: "Build 79 — Deleting a playlist now sticks",
      whatsNew: [
        "Fixed: deleting a playlist now actually removes it. Before, swiping a playlist and tapping Delete looked like it worked but the playlist came back on the next sync — because the deletion was never sent to the server.",
        "You can delete a playlist by swiping left on it, or by long-pressing it and choosing Delete Playlist. Either way you'll be asked to confirm, and the deletion now syncs across your devices.",
      ],
      testingFocus: [
        "Swipe left on a playlist and tap Delete, confirm the alert, and check it's gone — then reopen the app and confirm it hasn't come back.",
        "Long-press a playlist and choose Delete Playlist; confirm it's removed. Also try Cancel on the confirmation and check the playlist is left untouched.",
      ]
    ),
    ReleaseNote(
      id: 78,
      date: "2026-07-16",
      title: "Build 78 — No more silent duplicate adds",
      whatsNew: [
        "Fixed: adding a song that's already in a playlist no longer silently creates a hidden second copy. You now get the 'already in this playlist' prompt (or nothing happens) — the same handling you already got when adding several songs at once.",
        "The Create button in the New Playlist dialog now stays disabled until you type a name, so it can't be tapped to no effect.",
      ],
      testingFocus: [
        "Add a song to a playlist, then add that same song to the same playlist again. Confirm you're warned it's already there — no silent duplicate appears.",
        "Open Add-to-Playlist and tap +. Confirm Create is greyed out until you enter a name.",
      ]
    ),
    ReleaseNote(
      id: 77,
      date: "2026-07-16",
      title: "Build 77 — Create-Playlist-in-folder fix",
      whatsNew: [
        "Fixed a bug when you created a brand-new playlist from Add-to-Playlist while inside a folder: the playlist could go missing from that folder, a duplicate empty copy could appear, and your songs could end up split across the copies.",
        "Now creating a playlist this way makes exactly one playlist, files it into the folder you're in, and keeps every song you add to it — including tracks you add later.",
      ],
      testingFocus: [
        "Open Add-to-Playlist for a song, go into a folder, tap + to create a new playlist, and name it. Confirm exactly one playlist is created and it appears inside that folder.",
        "Later, add a second song to that same playlist. Confirm there's still just one playlist, it's still in the folder, and it holds both songs.",
      ]
    ),
    ReleaseNote(
      id: 76,
      date: "2026-07-14",
      title: "Build 76 — New app icon",
      whatsNew: [
        "New app icon — a bold Bauhaus-style speaker design. You'll see it on your home screen after this build installs.",
        "Add-to-Playlist search now also finds playlists tucked inside folders, matching how search already works on the main Playlists screen — so a quick search reaches every playlist, wherever it lives.",
      ],
      testingFocus: [
        "After installing, check the home-screen icon is the new speaker artwork (not the old one).",
        "Open Add-to-Playlist for a song, type the name of a playlist that lives inside a folder, and confirm it now appears in the results.",
      ]
    ),
    ReleaseNote(
      id: 75,
      date: "2026-07-14",
      title: "Build 75 — Playlist folders in Add-to-Playlist, plus Create Playlist",
      whatsNew: [
        "Add-to-Playlist now shows your playlist folders, not just loose playlists — tap a folder to open it and pick a playlist inside. It's the same folder view you see on the Playlists screen.",
        "The confusing search-bar-style 'new playlist' box at the top of Add-to-Playlist is gone. The + button at the bottom now creates a playlist (and drops the song you're adding straight into it).",
        "Add-to-Playlist no longer closes the moment you add one song — it stays open so you can add the same song to several playlists in a row, then close it yourself.",
        "The multi-select 'tick several playlists then commit' mode has been removed in favour of simple one-tap adding.",
        "The Playlists screen's ⋯ menu now has 'Create Playlist' (alongside New Folder).",
        "Searching at the top of the Playlists screen now finds playlists inside folders too, not just loose ones.",
      ],
      testingFocus: [
        "In Add-to-Playlist, confirm your folders appear and you can tap into a folder and add to a playlist inside it.",
        "Add a song, then add it again to another playlist without the sheet closing; close it yourself when done.",
        "Tap the + button, name a new playlist, and confirm the song you were adding lands in it (and that it's filed into the folder you were in, if any).",
        "On the Playlists screen, use ⋯ → Create Playlist; and search at the top level for a playlist that lives inside a folder — it should appear.",
      ]
    ),
    ReleaseNote(
      id: 74,
      date: "2026-07-12",
      title: "Build 74 — Navigation from the player no longer hijacks another tab",
      whatsNew: [
        "Fixed: navigation from the player could hijack another tab. Opening a page from the now-playing player — 'Show in Playlists', 'Show Album', 'Show Artist', 'Related Tracks', or tapping the artwork/title — while you were on the Home tab would drop that page onto the Library tab instead. You'd land there with no back button and no way to return to Home short of restarting the app. These now open on the tab you're already on, with a normal back button, and the player just collapses (playback keeps going).",
      ],
      testingFocus: [
        "On the Home tab, play a track, expand the mini player, tap the chevron/… → 'Show in Playlists'. The player should collapse and Playlists membership should push onto the HOME tab with a working back button. You should still be on Home, not yanked to Library.",
        "Repeat for 'Show Album', 'Show Artist', and 'Related Tracks' from the player — each should push onto the current tab with a back button; playback should continue.",
        "Tap the artwork or title inside the full-screen player to go to the album/artist — same expectation: opens on the current tab, back button works.",
        "From the Search tab and from a Library tab, confirm the same actions push onto whichever tab you were on (never a different one), and Back always returns you where you started.",
      ]
    ),
    ReleaseNote(
      id: 73,
      date: "2026-07-12",
      title: "Build 73 — Faster filing on Recently Added",
      whatsNew: [
        "Recently Added Tracks bulk-select now has a 'Select All' button in the edit bar — one tap ticks every track in the list. With the 'Hide tracks already in playlists' filter on, that's exactly your unfiled backlog, so you can file the whole inbox in a couple of taps. Tap again for 'Deselect All'.",
        "When the 'Hide tracks already in playlists' filter is on, the header now shows a small 'Filtered · N unfiled' caption so you can see at a glance how many tracks are left to file. It updates live as you file them.",
      ],
      testingFocus: [
        "Open Recently Added Tracks, tap options → 'Select Tracks'. Tap 'Select All' — every visible row should tick and the count should match. The button should flip to 'Deselect All'; tap it and everything should un-tick.",
        "Turn on 'Hide tracks already in playlists', then 'Select All' — only the visible (unfiled) tracks should be selected. Tap 'Add to Playlist…', pick a playlist; the added tracks should disappear from the list.",
        "With the filter on, 'Select All', then toggle the filter or file some tracks — the selection should reconcile (vanished tracks drop out) and the button should still read correctly.",
        "With the filter ON, confirm the header shows 'Filtered · N unfiled' and that N matches the visible count and drops as you file tracks. With the filter OFF, there should be NO caption (and no pop-up/toast).",
        "When the list is empty, 'Select All' should be disabled.",
      ]
    ),
    ReleaseNote(
      id: 72,
      date: "2026-07-11",
      title: "Build 72 — Steadier Gigs + tidier song rows",
      whatsNew: [
        "Gigs 'Near me' no longer hangs: if your location can't be found within a few seconds it now gives up cleanly and tells you, instead of leaving the button stuck. Tapping it twice quickly can't jam it any more.",
        "When you follow several cities and one of them can't refresh, Gigs now keeps showing the others and adds a small 'Couldn't refresh: <city>' note — rather than silently showing a stale or empty list.",
        "If a server doesn't offer gigs at all, Gigs now says 'Gigs isn't set up for this server yet' instead of an offline-looking message.",
        "Adding a city you already follow now says 'Already following <city>' instead of doing nothing.",
        "Gigs empty screens now match the rest of the app's look.",
        "VoiceOver now announces a song row's downloaded / favorite / downloading state in one read.",
      ],
      testingFocus: [
        "In Gigs, tap 'Near me' somewhere with poor GPS (or decline the prompt) — after a few seconds you should get a clear 'Location Unavailable' message and the button should work again. Double-tap it fast; it should not get stuck.",
        "Follow two or three cities where at least one server scope is down — the reachable cities should still list, with a 'Couldn't refresh: <city>' note at the top.",
        "On a server without the gigs service, Gigs should say 'Gigs isn't set up for this server yet'.",
        "Add a city you already follow (any casing) — expect 'Already following <city>'.",
        "With VoiceOver on, swipe through song rows — each should announce downloaded / favorite / downloading state, not just the title.",
        "Confirm song rows still look and lay out correctly (artwork, the two round trailing buttons, duration, the left-of-artwork downloaded dot).",
      ]
    ),
  ]
}
