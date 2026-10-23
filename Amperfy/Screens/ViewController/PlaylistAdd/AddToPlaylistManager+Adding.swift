//
//  AddToPlaylistManager+Adding.swift
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

/// Route 2's commit step: the "+" picker reached from inside a playlist's edit
/// screen.
///
/// Route 1 (`PlaylistSelectorVC`) and Route 2 both add songs to a playlist, and
/// before AMP-28 they disagreed about how. Route 2 was the worse of the two:
///
/// - It uploaded **server-first** and appended locally only after the request
///   returned, so until the round-trip finished the songs were nowhere — and if
///   the request failed they were nowhere permanently.
/// - It dismissed the sheet *before* starting the upload, so the one piece of
///   failure reporting it had (an `eventLogger` banner) was raised against a
///   view hierarchy that was mid-transition, and `onDoneCB` — the caller's
///   table reload — only ran on the success branch.
/// - The over-100-songs reassurance ("has been successfully synced to the
///   server") sat **outside** the `do`/`catch`, so it fired on the failure path
///   too. The user was told the sync succeeded by the same code path that had
///   just swallowed its error.
///
/// Both routes now do the same three things in the same order: append locally,
/// write the durable queue row in that same save, and only then hand off to
/// ``PlaylistAddUploadService``. The worker owns retry, rollback on a permanent
/// refusal, and the loud modal.
extension AddToPlaylistManager {
  private static let logger = Logger(subsystem: "Amperfy", category: "AddToPlaylistManager")

  /// Commit `songsToAdd` into the playlist: visible at once, owed to the server
  /// durably, dismissed immediately.
  func commitPendingAdds(songsToAdd: [Song]) {
    guard !songsToAdd.isEmpty else {
      rootView?.dismiss(animated: true, completion: nil)
      return
    }
    guard let account = playlist.account else {
      // No account means no syncer and no queue scoping. Previously this
      // branch silently skipped the upload and appended anyway — i.e. the exact
      // silent loss AMP-28 is about — so it is now reported.
      Self.logger
        .error("Playlist has no account; cannot queue its song adds for upload.")
      appDelegate.eventLogger.info(
        topic: "Add Songs to Playlist",
        message: "These songs could not be added: the playlist is not linked to a server account."
      )
      rootView?.dismiss(animated: true, completion: nil)
      return
    }

    // Local-first, and the enqueue saves the context, so the append and the
    // queue rows land in one save. There is no window in which the user can see
    // songs the device does not know it still owes the server.
    playlist.append(playables: songsToAdd)
    let uploadService = appDelegate.playlistAddUploadService(for: account)
    uploadService.enqueue(songs: songsToAdd, to: playlist)

    // The caller's refresh runs unconditionally now — the songs ARE in the
    // playlist locally, whatever the network goes on to do.
    onDoneCB?()
    rootView?.dismiss(animated: true, completion: nil)

    let didWarnAboutLargeBatch = songsToAdd.count > Self.warningElementsToAddCount
    let playlistName = playlist.name
    Task { @MainActor in
      let summary = await uploadService.flushPendingAdds()
      // Only claim a successful sync when one actually happened. A transient
      // failure or an offline device already gets its own banner from the
      // worker, and a permanent refusal gets a modal alert.
      guard didWarnAboutLargeBatch, summary.didUploadAnything, summary.isFullyDrained
      else { return }
      self.appDelegate.eventLogger.info(
        topic: "Add Songs to Playlist",
        message: "The Playlist \"\(playlistName)\" has been successfully synced to the server."
      )
    }
  }

  /// Bring the playlist's songs up to date so the picker's duplicate check has
  /// something authoritative to check against.
  ///
  /// Route 1 does the same thing (awaited, immediately before its check). Here
  /// it is deliberately *not* awaited: the picker is a multi-screen browse flow
  /// and selections accumulate in `elementsToAdd` rather than in the playlist,
  /// so a fetch landing mid-browse cannot disturb them — it only makes the next
  /// `notContaines` call more accurate. A failure is non-fatal; the check falls
  /// back to whatever items are already loaded, which is the old behaviour.
  func refreshPlaylistSongsForDuplicateCheck() {
    guard appDelegate.storage.settings.user.isOnlineMode,
          let account = playlist.account
    else { return }
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncDown(playlist: self.playlist)
      } catch {
        Self.logger.notice(
          """
          Could not refresh the playlist before the duplicate check; falling back to \
          the locally known items.
          """
        )
      }
    }
  }
}
