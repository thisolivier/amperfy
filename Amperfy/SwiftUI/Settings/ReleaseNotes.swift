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
