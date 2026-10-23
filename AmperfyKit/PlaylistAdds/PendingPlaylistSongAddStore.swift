//
//  PendingPlaylistSongAddStore.swift
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

import CoreData
import Foundation
import os.log

// MARK: - PendingPlaylistSongAddBatch

/// Every queued add for one playlist, collapsed into the single request the
/// Subsonic API wants (`updatePlaylist` takes a list of song ids).
public struct PendingPlaylistSongAddBatch {
  public let playlist: Playlist
  /// The songs to send, oldest-queued first. One entry per pending row, so a
  /// deliberate duplicate add stays a duplicate.
  public let songs: [Song]
  /// The rows that produced `songs`, in the same order.
  public let pendingAdds: [PendingPlaylistSongAdd]
}

// MARK: - PendingPlaylistSongAddStore

/// The queue of playlist song adds the server has not confirmed.
///
/// Before AMP-28 an add was a fire-and-forget `Task` on a view controller: the
/// songs appeared locally at once, the upload went out unawaited, and a refusal
/// (the Navidrome fork answers Subsonic error 50 for a playlist it considers
/// server-synced) was swallowed into a notification banner that any presented
/// modal suppresses. The next per-playlist fetch then truncated the local tail
/// back to what the server held, and the add was gone without a trace.
///
/// The fix is this queue. Every add writes a row here in the same save as the
/// optimistic local append, so the intent is durable before any network call
/// exists. Rows are deleted on exactly two outcomes — the upload landed, or the
/// server permanently refused it — and the refusal path rolls the local append
/// back and tells the user. Anything else (offline, timeout, 5xx) leaves the
/// row alone to be retried, with no attempt ceiling: a song the user put in a
/// playlist is not something to give up on. Same rule as
/// `PlaylistFolderStore+PendingCreation`.
///
/// Orphans are the one silent deletion. A library wipe or account cleanup can
/// leave a row whose playlist or song no longer exists locally; such a row can
/// never be uploaded, so it is swept instead of retried forever.
@MainActor
public final class PendingPlaylistSongAddStore {
  private let library: LibraryStorage
  private let logger = Logger(subsystem: "Amperfy", category: "PendingPlaylistSongAddStore")

  public init(library: LibraryStorage) {
    self.library = library
  }

  // MARK: - Enqueueing

  /// Record `songs` as owed to `playlist`. Saves immediately: an add that is
  /// only in memory is exactly the failure mode this queue exists to end.
  ///
  /// - Returns: the rows created, in request order.
  @discardableResult
  public func enqueue(
    songs: [Song],
    to playlist: Playlist,
    account: Account,
    now: Date = Date()
  )
    -> [PendingPlaylistSongAdd] {
    guard !songs.isEmpty else { return [] }

    var createdRows = [PendingPlaylistSongAdd]()
    // A shared timestamp would make the FIFO sort unstable within one batch, so
    // each row gets a strictly increasing one a microsecond apart. Far below
    // anything a user can perceive, and enough for `createdAt` alone to be a
    // total order.
    for (offsetInBatch, song) in songs.enumerated() {
      let pendingAdd = library.createPendingPlaylistSongAdd(account: account)
      pendingAdd.playlist = playlist
      pendingAdd.song = song
      pendingAdd.createdAt = now.addingTimeInterval(Double(offsetInBatch) * 0.000_001)
      createdRows.append(pendingAdd)
    }
    library.saveContext()
    logger.info(
      """
      Queued \(createdRows.count, privacy: .public) playlist song add(s) for upload.
      """
    )
    return createdRows
  }

  // MARK: - Reading

  /// Pending work for `account`, grouped by playlist, playlists in the order
  /// their oldest pending add was made.
  ///
  /// Orphaned rows are swept here rather than returned: this is the one place
  /// every reader passes through.
  public func pendingBatches(for account: Account) -> [PendingPlaylistSongAddBatch] {
    let pendingAdds = sweepOrphans(in: library.getPendingPlaylistSongAdds(for: account))
    return groupIntoBatches(pendingAdds)
  }

  /// Pending work for one playlist, oldest first. Used by the
  /// post-`syncDown` reconciliation guard.
  public func pendingAdds(for playlist: Playlist) -> [PendingPlaylistSongAdd] {
    sweepOrphans(in: library.getPendingPlaylistSongAdds(for: playlist))
  }

  public func pendingAddCount(for account: Account) -> Int {
    library.getPendingPlaylistSongAdds(for: account).count
  }

  public var hasAnyPendingAdds: Bool {
    !library.getAllPendingPlaylistSongAdds().isEmpty
  }

  /// Accounts that currently owe the server at least one add. Drives the
  /// foreground flush without assuming the active account is the only one with
  /// work outstanding.
  public func accountsWithPendingAdds() -> [Account] {
    var accountsByObjectId = [NSManagedObjectID: Account]()
    for pendingAdd in library.getAllPendingPlaylistSongAdds() {
      guard let account = pendingAdd.account else { continue }
      accountsByObjectId[account.managedObject.objectID] = account
    }
    return Array(accountsByObjectId.values)
  }

  // MARK: - Resolving outcomes

  /// The upload landed (or the server permanently refused it) — either way the
  /// rows have had their answer and must not be retried.
  public func delete(_ pendingAdds: [PendingPlaylistSongAdd]) {
    guard !pendingAdds.isEmpty else { return }
    for pendingAdd in pendingAdds {
      library.deletePendingPlaylistSongAdd(pendingAdd)
    }
    library.saveContext()
  }

  /// A transient failure: keep the rows, remember why, and count the attempt.
  public func recordTransientFailure(
    for pendingAdds: [PendingPlaylistSongAdd],
    message: String
  ) {
    guard !pendingAdds.isEmpty else { return }
    for pendingAdd in pendingAdds {
      pendingAdd.attemptCount += 1
      pendingAdd.lastErrorMessage = message
    }
    library.saveContext()
    logger.warning(
      """
      \(pendingAdds.count, privacy: .public) playlist song add(s) still pending after a \
      transient failure; they stay queued and will be retried.
      """
    )
  }

  // MARK: - Internals

  private func groupIntoBatches(_ pendingAdds: [PendingPlaylistSongAdd])
    -> [PendingPlaylistSongAddBatch] {
    var batchOrder = [NSManagedObjectID]()
    var rowsByPlaylistObjectId = [NSManagedObjectID: [PendingPlaylistSongAdd]]()
    var playlistsByObjectId = [NSManagedObjectID: Playlist]()

    for pendingAdd in pendingAdds {
      guard let playlist = pendingAdd.playlist, pendingAdd.song != nil else { continue }
      let playlistObjectId = playlist.managedObject.objectID
      if rowsByPlaylistObjectId[playlistObjectId] == nil {
        batchOrder.append(playlistObjectId)
        playlistsByObjectId[playlistObjectId] = playlist
      }
      rowsByPlaylistObjectId[playlistObjectId, default: []].append(pendingAdd)
    }

    return batchOrder.compactMap { playlistObjectId in
      guard let playlist = playlistsByObjectId[playlistObjectId],
            let rows = rowsByPlaylistObjectId[playlistObjectId]
      else { return nil }
      return PendingPlaylistSongAddBatch(
        playlist: playlist,
        songs: rows.compactMap(\.song),
        pendingAdds: rows
      )
    }
  }

  /// Drop rows whose playlist or song no longer exists locally and return the
  /// rest.
  private func sweepOrphans(in pendingAdds: [PendingPlaylistSongAdd])
    -> [PendingPlaylistSongAdd] {
    let orphanedAdds = pendingAdds.filter(\.isOrphaned)
    guard !orphanedAdds.isEmpty else { return pendingAdds }
    logger.notice(
      """
      Sweeping \(orphanedAdds.count, privacy: .public) orphaned pending playlist song add(s): \
      the playlist or song no longer exists on this device.
      """
    )
    delete(orphanedAdds)
    return pendingAdds.filter { !orphanedAdds.contains($0) }
  }
}
