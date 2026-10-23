//
//  PendingPlaylistSongAddReconciler.swift
//  AmperfyKit
//
//  Created for AMP-28 — playlist song adds became a durable, retried queue.
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

/// Puts back the local items a per-playlist fetch just took away.
///
/// Reconciliation is server-wins and positional: `SsPlaylistSongsParserDelegate`
/// rebuilds `Playlist.items` from the response envelope, so anything local that
/// the server does not know about is deleted. For a *pending* add that is
/// exactly wrong — the add has not reached the server yet, so of course the
/// envelope omits it, and truncating it is how an add the user could see became
/// an add that silently never existed.
///
/// The guard runs after EVERY per-playlist fetch (one choke point:
/// `LibrarySyncerProxy.syncDown(playlist:)`, which every caller including
/// `Playlist.fetchFromServer` routes through) and re-appends any queued song
/// the fetch left absent. Pending folder creations are protected from
/// reconciliation the same way — local-first work awaiting push is never server
/// state to mirror.
///
/// Known simplification: presence, not multiplicity. A queued song that is
/// already present once is left alone, so a *deliberate duplicate* add that
/// coincides with a mid-flight fetch can come back as one copy instead of two.
/// The alternative — appending every queued row unconditionally — would double
/// every add whose upload actually succeeded while we believed it had not, a
/// strictly worse failure.
public enum PendingPlaylistSongAddReconciler {
  private static let logger = Logger(
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
    logger.notice(
      """
      Restored \(songsToRestore.count, privacy: .public) still-queued song(s) a playlist \
      fetch had removed; they remain queued for upload.
      """
    )
    return songsToRestore.count
  }
}
