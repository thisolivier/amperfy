//
//  RecentTracksPlaybackResolver.swift
//  AmperfyKit
//
//  Created by implementer-amperfy on 2026-07-02.
//  Copyright (c) 2026 Amperfy. All rights reserved.
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

/// Resolves a `PlayContext` for a tap on the "Recently Added Tracks" synthetic
/// detail view (`RecentTracksDetailVC`) by the tapped song's stable identity,
/// rather than by the row index/position it was tapped at.
///
/// The detail view wholesale-replaces its `songs` array on every
/// `viewIsAppearing`, pull-to-refresh, and mode/stepper change. Both of its
/// tap-handling paths only learn the tap actually happened some time after
/// the user touched the row — long enough for a reload to have already
/// swapped `songs` out from under them. Resolving playback purely from "the
/// row index that was touched" then risks starting playback on whatever song
/// now occupies that index/position, which may not be the song the user saw
/// and touched.
///
/// This resolver sidesteps that race: it is handed the tapped song's stable
/// id (captured at the moment the cell was configured, before any reload
/// could have happened) and re-finds that song's CURRENT index in whatever
/// `songs` holds now, building the `PlayContext` from that. If the tapped
/// song is no longer present, it returns `nil` — a graceful no-op is correct
/// here, not a crash or a fallback to some arbitrary other song.
public enum RecentTracksPlaybackResolver {
  /// Finds `tappedSongId` in `currentSongs` and builds a `PlayContext` that
  /// starts playback at its current index.
  ///
  /// - Parameters:
  ///   - tappedSongId: The stable `id` of the song the user actually tapped,
  ///     captured at cell-configuration time (unaffected by any reload that
  ///     happened between touch and this call).
  ///   - name: The display name for the resulting `PlayContext` (e.g.
  ///     "Recently Added Tracks").
  ///   - currentSongs: The `songs` array as it stands right now — may differ
  ///     from what was on screen when the user touched the row.
  /// - Returns: A `PlayContext` starting at the tapped song's current index,
  ///   or `nil` if the tapped song is no longer present in `currentSongs`.
  public static func resolvePlayContext(
    tappedSongId: String,
    name: String,
    currentSongs: [Song]
  )
    -> PlayContext? {
    guard let currentIndex = currentSongs.firstIndex(where: { $0.id == tappedSongId })
    else { return nil }
    return PlayContext(name: name, index: currentIndex, playables: currentSongs)
  }
}
