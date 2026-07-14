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
    ReleaseNote(
      id: 71,
      date: "2026-07-11",
      title: "Build 71 — Triage your Recently Added tracks",
      whatsNew: [
        "Recently Added Tracks now has a filter: tap the options button (top right) and turn on 'Hide tracks already in playlists' to see only the tracks you still need to file. It's a triage inbox — once a track is in a playlist, it drops off the list.",
        "New bulk-select: on Recently Added Tracks, tap the options button and choose 'Select Tracks', tick as many as you like, then 'Add to Playlist…' to file them all at once. With the filter on, the tracks you just added disappear from the list right away — inbox zero.",
        "The filter is off by default and remembers your choice. Smart playlists don't count (a track only in a smart playlist still shows), and playlists from other accounts are ignored.",
      ],
      testingFocus: [
        "Open Recently Added Tracks, tap the options button, and toggle 'Hide tracks already in playlists'. Add one of the listed tracks to a playlist, come back — it should disappear when the filter is on, reappear when off.",
        "Tap options → 'Select Tracks', tick several tracks (the count updates), tap 'Add to Playlist…', pick a playlist. All ticked tracks should be added; check the playlist to confirm.",
        "With the filter ON, bulk-add some tracks, then reopen the list — the added tracks should be gone (they're now filed).",
        "Remove a track from its only playlist and reopen the list with the filter on — the track should come back.",
        "With the filter on and every recent single already filed, the list should show a 'Nothing left to file' message, not a blank screen.",
        "Confirm the Home tab's Recently Added preview row is unchanged (it stays unfiltered).",
        "Toggle the filter, force-quit and relaunch — your choice should stick.",
      ]
    ),
  ]
}
