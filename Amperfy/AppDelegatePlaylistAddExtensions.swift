//
//  AppDelegatePlaylistAddExtensions.swift
//  Amperfy
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

import AmperfyKit
import OSLog
import UIKit

/// The app-side wiring for the AMP-28 pending-adds queue: one factory, and the
/// retry trigger.
extension AppDelegate {
  /// The queue itself — one store over the main context, shared by every route
  /// that adds songs to a playlist.
  var pendingPlaylistSongAddStore: PendingPlaylistSongAddStore {
    PendingPlaylistSongAddStore(library: storage.main.library)
  }

  /// An upload worker bound to `account`, with failure reporting already wired:
  /// a permanent refusal becomes a modal alert the presented picker cannot
  /// swallow, a transient one becomes a non-blocking banner.
  func playlistAddUploadService(for account: Account) -> PlaylistAddUploadService {
    PlaylistAddUploadService(
      store: pendingPlaylistSongAddStore,
      librarySyncer: getMeta(account.info).librarySyncer,
      account: account,
      isOnline: { [weak self] in
        guard let self else { return false }
        return storage.settings.user.isOnlineMode && networkMonitor.isConnectedToNetwork
      },
      reportPermanentFailure: { [weak self] failure in
        guard let self else { return }
        LoudFailureAlertPresenter.presentPlaylistAddRefusal(failure, eventLogger: eventLogger)
      },
      reportTransientFailure: { [weak self] error in
        guard let self else { return }
        eventLogger.report(topic: "Add Songs to Playlist", error: error)
      }
    )
  }

  /// Retry every account's outstanding adds.
  ///
  /// Called on scene foreground (beside the playlist item-sync resume) rather
  /// than on a timer: the retry rate wants to be bounded by the user coming
  /// back to the app, not by a poll. Every account with pending work is
  /// flushed, not just the active one — a queued add on a signed-in-but-not-
  /// selected account would otherwise wait forever.
  func flushPendingPlaylistSongAdds() {
    let accountsWithPendingAdds = pendingPlaylistSongAddStore.accountsWithPendingAdds()
    guard !accountsWithPendingAdds.isEmpty else { return }
    os_log(
      "Flushing pending playlist song adds for %i account(s)",
      log: log,
      type: .info,
      accountsWithPendingAdds.count
    )
    for account in accountsWithPendingAdds {
      let uploadService = playlistAddUploadService(for: account)
      Task { @MainActor in
        await uploadService.flushPendingAdds()
      }
    }
  }
}
