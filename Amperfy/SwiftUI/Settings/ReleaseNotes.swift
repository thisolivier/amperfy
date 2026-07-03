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
    ReleaseNote(
      id: 56,
      date: "2026-07-02",
      title: "Build 56 — Fixed wrong song playing from Recently Added Tracks",
      whatsNew: [
        "Fixed a bug where tapping a track in Recently Added Tracks could start playing a different song than the one you tapped",
        "This could happen right after the list refreshed (e.g. new tracks synced in) while you were tapping a row",
      ],
      testingFocus: [
        "Open Recently Added Tracks, let new tracks sync in or pull-to-refresh, then tap a track — the song that plays should always match the one you tapped",
        "Tap a track immediately after switching between 'Top N' and 'Last M days' modes, or after adjusting the count stepper — playback should still match the tapped row",
        "General regression: tapping any track in this list should behave exactly as before when no refresh has just happened",
      ]
    ),
    ReleaseNote(
      id: 55,
      date: "2026-07-01",
      title: "Build 55 — Recently added tracks widget always renders",
      whatsNew: [
        "Recently Added Tracks no longer disappears from the Home screen — once you've added it, it always shows",
        "The widget shows up to 10 of your most recently added individually-added/single-ish tracks, regardless of how old the newest ones are",
        "Whole albums are still deliberately excluded from this widget (see the separate recent-albums section) — a library whose recent additions are all whole albums will correctly show an empty (but present) widget",
      ],
      testingFocus: [
        "Home screen: Recently Added Tracks should always appear once added to Home, even on a lightly-used or freshly-synced library",
        "A library with only whole-album recent additions (no individual singles/loose tracks) should show an empty Recently Added Tracks widget, not a hidden one",
        "A library with fewer than 10 qualifying (non-whole-album) songs should show everything it has in the widget",
        "Tapping a tile in Recently Added Tracks should still open the recent tracks detail view as before",
      ]
    ),
    ReleaseNote(
      id: 53,
      date: "2026-05-24",
      title: "Build 53 — Related tracks bulk queue",
      whatsNew: [
        "Play All or Shuffle All related tracks from the modal toolbar",
        "Add all related tracks to queue (insert or append, user or context queue)",
        "Removed per-song swipe actions that conflicted with existing detail UI",
      ],
      testingFocus: [
        "Play a song → open Related Tracks → tap Play All: should start playing all related tracks",
        "Tap Shuffle: should play related tracks in random order",
        "Tap queue button → Insert User Queue: all tracks appear at start of queue",
        "Tap queue button → Append User Queue: all tracks appear at end of queue",
        "In offline mode: only cached tracks should be included in queue actions",
        "Individual song cells should still show detail view on tap (no swipe actions)",
      ]
    ),
  ]
}
