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
    ReleaseNote(
      id: 65,
      date: "2026-07-09",
      title: "Build 65 — Related Tracks controls and honest playlist membership",
      whatsNew: [
        "Related Tracks: the bulk-queue controls are no longer hidden behind the tab bar and mini player — the toolbar now sits clear of the safe area on iPhone, so you can reach every action",
        "Playlist membership ('Show in Playlists') is now accurate — it no longer misses playlists a song is really in",
      ],
      testingFocus: [
        "Open a Related Tracks deck on iPhone with the mini player showing — the bulk-queue controls should be fully visible and tappable, not clipped by the tab bar",
        "Open 'Show in Playlists' for a song you know is in several playlists — every one should be listed, none missing",
      ]
    ),
    ReleaseNote(
      id: 64,
      date: "2026-07-08",
      title: "Build 64 — Needle-drop previews you can hear",
      whatsNew: [
        "Needle-drop previews now play sound: the audio session is activated for the preview, so you can actually hear tracks while auditioning them from a recommendation card",
      ],
      testingFocus: [
        "Open a recommendation deck and touch a needle-drop bar — you should now hear the track preview, not silence",
        "After a preview, your own music should resume as before",
      ]
    ),
    ReleaseNote(
      id: 63,
      date: "2026-07-05",
      title: "Build 63 — An honest Recently Added list",
      whatsNew: [
        "Recently Added is now accurate: the after-import triplicates can no longer occur (fixed at the source, not papered over), and tracks deleted on the server disappear from the list promptly — including old ghosts already on your device, healed on first launch",
        "Deleted-but-cached tracks: still playable from cache until you clear it (that behavior is deliberate and kept), then they vanish cleanly instead of erroring",
        "Opening a recommendation deck no longer pauses your music — playback only pauses when you actually start a preview, and resumes after",
        "Settings now shows gateway status under the key fields: last request result and when",
      ],
      testingFocus: [
        "Import something via SoulseekNavi, watch Recently Added during the scan — no duplicates at any point",
        "Recently Added should now match what NaviAdmin/Navidrome say is real",
        "Play music, open a recommendation deck — music keeps playing; touch a needle-drop bar — it pauses; leave — it resumes",
        "Settings → gateway fields → status line should show your last gateway request",
      ]
    ),
    ReleaseNote(
      id: 62,
      date: "2026-07-05",
      title: "Build 62 — Discovery works away from home",
      whatsNew: [
        "New in Settings: Gateway URL and Gateway Key — set both and Discovery's recommendations and previews work anywhere, not just on your home network",
        "With a gateway configured, the app uses it everywhere (home included) — one path, no mode switching",
        "Discovery Diagnostics now shows whether each request went via the gateway or direct, and the connection test tells you a rejected key apart from an unreachable server",
      ],
      testingFocus: [
        "Settings → set Gateway URL (your soul.beat.online address, port 5040) and the key — then deal a deck OFF your home network: cards and previews should work",
        "Diagnostics → Test Connection should show gateway mode, 200, and a latency",
        "Clear the gateway fields → behavior reverts to home-network-only, as before",
      ]
    ),
  ]
}
