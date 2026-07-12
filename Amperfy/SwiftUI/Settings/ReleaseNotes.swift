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
    ReleaseNote(
      id: 70,
      date: "2026-07-09",
      title: "Build 70 — Gigs fixes + cleaner song rows",
      whatsNew: [
        "Gigs now shows every valid show: a few venues with missing details (or a date but no time) used to hide a whole city's gigs — those shows now appear, with a 'Venue TBA' note and an all-day date where needed.",
        "Tapping a gig opens its tickets inside Amperfy and returns you to the Gigs list when you close it; long-press a gig for 'Open in Safari'.",
        "You can now see and remove the cities you follow — tap the list button in Gigs to manage them.",
        "Song rows are cleaner: the downloaded dot now sits on the left of the artwork, and the two round buttons (actions and explore) are evenly sized.",
        "When a source lists the same show twice, Amperfy now keeps the Ticketmaster listing, and empty cities say so instead of showing a blank list.",
      ],
      testingFocus: [
        "Add a city with some shows that have missing venues or date-only listings (e.g. a Ticketmaster-heavy city) — every valid show should appear, none silently dropped.",
        "Tap a gig, then close the ticket page — you should land back on the Gigs list, not Home. Long-press a gig and choose 'Open in Safari'.",
        "In Gigs, tap the list button, then swipe or use Edit to remove a city — the Gigs list should update.",
        "On song rows, confirm the downloaded dot is on the left of the album art and the two round trailing buttons are the same size; download a song and watch the dot appear live.",
        "If you upgraded from an older build and never saw the Gigs tab, it should now appear in the library list automatically.",
      ]
    ),
    ReleaseNote(
      id: 69,
      date: "2026-07-09",
      title: "Build 69 — Gigs + cleaner song menus",
      whatsNew: [
        "New: a Gigs tab shows upcoming live shows for the artists in your library. Add cities to follow, or tap the location button to find gigs near you, then tap a gig to open its ticket page.",
        "Song menus are tidier: the … button now holds actions (play, queue, favorite, download, share), and a new chevron next to it holds ways to explore — Show Album, Show Artist, Show in Playlists, Related Tracks and Lyrics.",
      ],
      testingFocus: [
        "Open the Gigs tab (enable it from the library tab bar if hidden). With no cities added you should see a friendly prompt to add a city or use your location.",
        "Add a city in Gigs — with the gigs service offline you should get a clear 'couldn't reach / nothing cached' message, not a spinner or crash.",
        "Tap 'Near me' in Gigs — the app should ask for location permission only at that moment (never at launch).",
        "On any song row, tap the … button (actions only) and the new chevron (Show Album/Artist/Playlists/Related Tracks/Lyrics) — no item should appear in both menus.",
        "Check song rows across Search, album detail, playlist detail, the queue and the popup player — the two buttons should render and behave sanely everywhere; the queue's reorder handle and checkmarks should be unaffected.",
      ]
    ),
    ReleaseNote(
      id: 68,
      date: "2026-07-09",
      title: "Build 68 — Reliability hardening",
      whatsNew: [
        "Reliability: fixed a rare cause of the 'search could not be parsed' message on your first search, and made the mini player more robust against briefly showing the wrong track.",
      ],
      testingFocus: [
        "Do your very first search right after launch a few times — no 'search could not be parsed' message should appear",
        "Start a track so the mini player shows it, then background and reopen the app — the mini player should still show the correct track, and tapping it opens the full player with that track",
      ]
    ),
    ReleaseNote(
      id: 67,
      date: "2026-07-09",
      title: "Build 67 — Consistent player + quieter first search",
      whatsNew: [
        "Fixed: the full player could show 'No music playing' after tapping the mini player during a library sync.",
        "Fixed: a harmless 'search could not be parsed' message that could flash on your first search.",
      ],
      testingFocus: [
        "Start a track so the mini player shows it, then tap the mini player during a sync — the full player should show the SAME track, never 'No music playing'",
        "Do your very first search right after launch — no 'XML response could not be parsed' banner should appear",
      ]
    ),
    ReleaseNote(
      id: 66,
      date: "2026-07-09",
      title: "Build 66 — Reachable Related Tracks controls + faster Show in Playlists",
      whatsNew: [
        "Related Tracks: the play/shuffle/queue controls now sit above the mini player and tab bar so they're reachable.",
        "'Show in Playlists' is fast again — it no longer re-syncs your whole library each time you open it.",
      ],
      testingFocus: [
        "Start playback so the mini player shows, then open Related Tracks on iPhone — the play/shuffle/queue controls should sit above the mini player with a clear gap, not clipped behind it",
        "Open 'Show in Playlists' for a song a few times — it should open instantly without triggering a full library sync",
      ]
    ),
  ]
}
