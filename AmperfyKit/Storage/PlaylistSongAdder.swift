//
//  PlaylistSongAdder.swift
//  AmperfyKit
//
//  Created for the Recently Added bulk-select feature.
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

/// The single "add these songs to this playlist" operation, extracted so the
/// bulk-add-N path is unit-testable against a mock `LibrarySyncer`.
///
/// This mirrors `PlaylistSelectorVC.addSongsToSelectedPlaylists()` exactly and
/// deliberately: the server upload happens **first**, then the local append.
/// Keeping the two in step means the bulk-select entry point on Recently Added
/// and the app-wide add-to-playlist swipe/menu flow can't drift apart. The
/// picker UI on Recently Added still reuses `PlaylistSelectorVC` (which calls
/// this same ordering); this helper exists so that ordering has a home that a
/// test can drive with a recording syncer.
public enum PlaylistSongAdder {
  /// Uploads `songs` to `playlist` on the server, then appends them locally.
  ///
  /// The order is load-bearing: on a sync failure the local library is left
  /// unchanged (the append never runs), so we never show songs in a playlist
  /// the server rejected. Callers surface the thrown error via `eventLogger`
  /// per house convention.
  @MainActor
  public static func add(
    songs: [Song],
    to playlist: Playlist,
    using syncer: LibrarySyncer
  ) async throws {
    guard !songs.isEmpty else { return }
    try await syncer.syncUpload(playlistToAddSongs: playlist, songs: songs)
    playlist.append(playables: songs)
  }
}
