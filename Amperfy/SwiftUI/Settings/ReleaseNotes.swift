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
  ]
}
