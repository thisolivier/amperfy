//
//  PendingPlaylistSongAddReconciler.swift
//  AmperfyKit
//
//  Created by Olivier Butler on 23.10.26.
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
import os.log

/// Puts back the local items a per-playlist fetch has just taken away.
///
/// Reconciliation is server-wins and positional: the playlist-songs parsers
/// rebuild `Playlist.items` from the response envelope, so anything local the
/// server does not know about is deleted. For a *pending* add that is exactly
/// wrong — the add has not reached the server yet, so of course the envelope
/// omits it, and dropping it is how an add the user could see became an add
/// that silently never existed.
///
/// The guard runs after every per-playlist fetch (one choke point:
/// `LibrarySyncerProxy.syncDown(playlist:)`, which every caller including
/// `Playlist.fetchFromServer` routes through) and re-appends any queued song
/// the fetch left absent.
///
/// It compares presence, not multiplicity: a queued song that is already there
/// once is left alone, so a deliberate duplicate add that coincides with a
/// mid-flight fetch can come back as one copy instead of two. The alternative —
/// appending every queued add unconditionally — would double every add whose
/// upload actually succeeded while we believed it had not, which is worse.
public enum PendingPlaylistSongAddReconciler {
  private static let log = OSLog(
    subsystem: "Amperfy",
    category: "PendingPlaylistSongAddReconciler"
  )

  /// Re-append every queued song for `playlist` that is no longer among its
  /// items.
  ///
  /// - Returns: how many items were restored.
  @MainActor
  @discardableResult
  public static func reapplyPendingAdds(
    to playlist: Playlist,
    store: PendingPlaylistSongAddStore
  )
    -> Int {
    let pendingAdds = store.pendingAdds(for: playlist)
    guard !pendingAdds.isEmpty else { return 0 }

    let presentPlayableObjectIds = Set(playlist.playables.map(\.objectID))
    var songsToRestore = [Song]()
    for pendingAdd in pendingAdds {
      guard let song = pendingAdd.song else { continue }
      guard !presentPlayableObjectIds.contains(song.objectID) else { continue }
      songsToRestore.append(song)
    }
    guard !songsToRestore.isEmpty else { return 0 }

    playlist.append(playables: songsToRestore)
    os_log(
      "Restored %i still-queued song(s) a playlist fetch had removed",
      log: log,
      type: .info,
      songsToRestore.count
    )
    return songsToRestore.count
  }
}
