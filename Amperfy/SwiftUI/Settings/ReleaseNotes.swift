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
      id: 61,
      date: "2026-07-05",
      title: "Build 61 — Related Tracks polish + Discovery diagnostics",
      whatsNew: [
        "Related Tracks: proper large title that collapses as you scroll, row layout now matches playlist views, and the seed track wears an accent-colored border on a clean transparent badge",
        "Slow recommendation deals fail fast now: if the recommendation server can't be reached, the app gives up in ~5 seconds and falls back, instead of stalling for minutes",
        "New: Settings → Discovery Diagnostics — see exactly what every deal and preview fetch did (which server, how long, what failed), test the server connection, and Export Logs to share",
      ],
      testingFocus: [
        "Related Tracks: large title should shrink into the bar on scroll; rows should align like a playlist; seed badge = accent border, no fill",
        "Deal a deck on your long 'rock' playlist — it should resolve or fall back within seconds, not minutes",
        "Settings → Discovery Diagnostics → deal a deck, then Export Logs and send me the file — it lines up 1:1 with the server logs via the deal id",
      ]
    ),
    ReleaseNote(
      id: 60,
      date: "2026-07-04",
      title: "Build 60 — Discovery deck v2",
      whatsNew: [
        "The recommendation deck is now a normal page: it slides in, and tapping a card opens that collection — going back returns to your deck exactly as you left it, no re-deal",
        "Cleaner cards: no more Play/menu buttons or blend slider — just the card, the needle-drop bar, and a like button in the corner",
        "The page uses your theme (gradient background, accent title: 'Recommended Playlists from …') instead of the forced-dark look",
        "Previews no longer auto-play — the needle-drop bar plays only when you touch it",
        "Recommendations now come from the server-side engine by default (quality-verified against the on-device one), with automatic fallback when you're away from the server",
      ],
      testingFocus: [
        "Find similar playlists → tap a card → back: you should land on the same deck, same position, instantly",
        "Check the deck matches your theme (gradient + accent title) in both light and dark",
        "Cards should be silent until you drag the needle-drop bar (home network: previews are pre-rendered now, bars should show segments)",
        "Like from the card corner; open a card; play from inside the collection — back should still return to the deck",
      ]
    ),
    ReleaseNote(
      id: 59,
      date: "2026-07-03",
      title: "Build 59 — Related Tracks becomes a real page",
      whatsNew: [
        "Related Tracks now pushes in like any other page — with a proper header showing the track you came from — instead of opening as a floating sheet",
        "'Show in Playlists' works again and also pushes in; picking a playlist stacks its detail on top so you can navigate back the way you came",
        "Menus opened from the Now Playing popup no longer silently swallow actions like Add to Playlist",
      ],
      testingFocus: [
        "Track menu → Related Tracks: should slide in with a back button and a 'Related Tracks To:' header showing the original track",
        "From a related track's menu → Show in Playlists → pick a playlist → back, back, back — you should retrace your exact steps",
        "From the Now Playing popup, try Add to Playlist and Show in Playlists — both should appear reliably",
      ]
    ),
    ReleaseNote(
      id: 58,
      date: "2026-07-03",
      title: "Build 58 — Discovery polish from your first test drive",
      whatsNew: [
        "The first card of a deck now auto-auditions the moment it's dealt (it used to sit silent until you swiped)",
        "'Open' in a card's menu now actually takes you to the playlist/album",
        "Mega-playlists (folder playlists, imported liked-songs dumps) are no longer recommended",
        "Blend changes and Deal More no longer come up short when you've already seen the top matches — the deck digs deeper into the ranking",
      ],
      testingFocus: [
        "Open a deck and just wait — the first card should start auditioning by itself within about a second",
        "Card menu (···) → Open — should land on that collection's detail screen",
        "Playlists with many hundreds of tracks should no longer appear as recommendations",
        "Move the blend slider back and forth a few times — the deck should refill with fresh cards rather than shrinking",
      ]
    ),
    ReleaseNote(
      id: 57,
      date: "2026-07-03",
      title: "Build 57 — Discovery: Audition Deck + Needle Drop",
      whatsNew: [
        "New Discovery experience: 'Find similar playlists' and 'Find similar albums' in the playlist/album detail menus deal a full-screen deck of recommended collections",
        "Each card has a Needle Drop bar — drag across it to audition ~1.5s slices of every track, like running a thumb across a crate of vinyl; cards auto-audition as you swipe",
        "Blend slider mixes Familiar (close matches from your library's listening patterns) with Adventurous (new directions) recommendations",
        "Like button, Play-from-track handoff to the main player, deal-more, and 'Find more' doors on Home widget sections",
      ],
      testingFocus: [
        "Open 'Find similar playlists' on a playlist you know well — do the recommendations make sense, and do evidence lines read honestly?",
        "Drag the Needle Drop bar: audio slices should start near-instantly and follow your finger; releasing should keep riding through tracks",
        "Tap Play mid-audition — the main player should take over with the picked track, and sprite audio must stop dead",
        "Album previews render on first visit lazily: a card may say 'Preview unavailable' once, then have a working bar next time you open a deck for it",
        "Swipe fast between cards — audio must never come from two sources at once",
      ]
    ),
  ]
}
