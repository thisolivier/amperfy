//
//  PendingPlaylistSongAddStore.swift
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

import CoreData
import Foundation
import os.log

// MARK: - PendingPlaylistSongAddBatch

/// Every queued add for one playlist, collapsed into the single request the
/// backends want (`updatePlaylist` takes a list of song ids).
public struct PendingPlaylistSongAddBatch {
  public let playlist: Playlist
  /// The songs to send, oldest-queued first. One entry per queued add, so a
  /// deliberate duplicate stays a duplicate.
  public let songs: [Song]
  /// The queued adds that produced `songs`, in the same order.
  public let pendingAdds: [PendingPlaylistSongAdd]
}

// MARK: - PendingPlaylistSongAddStore

/// The queue of playlist song adds the server has not confirmed yet.
///
/// Playlist adds used to be fire-and-forget: the songs appeared locally at
/// once, the upload went out unawaited, and nothing remembered whether it had
/// landed. An offline device, a timeout or a server refusal all ended the same
/// way — the next per-playlist `syncDown` is server-wins and positional, so it
/// rewrote `items` from the response envelope and the local-only songs were
/// gone without a trace.
///
/// This queue is the durable record that was missing. An add is written here in
/// the same save as the optimistic local append, so the intent survives the
/// request failing, the device being offline, and the app being killed. Rows
/// are deleted on exactly two outcomes — the upload landed, or the server
/// permanently refused it — and the refusal path rolls the local append back.
/// Anything else leaves the row alone to be retried, with no attempt ceiling.
///
/// Orphans are the one silent deletion: a library wipe can leave an add whose
/// playlist, song or account no longer exists locally, and such an add can
/// never be uploaded.
@MainActor
public final class PendingPlaylistSongAddStore {
  private let library: LibraryStorage
  private let log = OSLog(subsystem: "Amperfy", category: "PendingPlaylistSongAddStore")

  public init(library: LibraryStorage) {
    self.library = library
  }

  // MARK: - Queueing

  /// Record `songs` as owed to `playlist`. Saves immediately: an add that is
  /// only in memory is exactly the failure this queue exists to end.
  ///
  /// - Returns: the queued adds, in request order.
  @discardableResult
  public func enqueue(
    songs: [Song],
    to playlist: Playlist,
    account: Account,
    now: Date = Date()
  )
    -> [PendingPlaylistSongAdd] {
    guard !songs.isEmpty else { return [] }

    var createdAdds = [PendingPlaylistSongAdd]()
    // A shared timestamp would make the FIFO sort unstable within one batch, so
    // each add gets a strictly increasing one a microsecond apart. That is far
    // below anything a user can perceive and enough for `createdAt` alone to be
    // a total order.
    for (offsetInBatch, song) in songs.enumerated() {
      let pendingAdd = library.createPendingPlaylistSongAdd(account: account)
      pendingAdd.playlist = playlist
      pendingAdd.song = song
      pendingAdd.createdAt = now.addingTimeInterval(Double(offsetInBatch) * 0.000_001)
      createdAdds.append(pendingAdd)
    }
    library.saveContext()
    os_log("Queued %i playlist song add(s) for upload", log: log, type: .info, createdAdds.count)
    return createdAdds
  }

  // MARK: - Reading

  /// Pending work for `account`, grouped by playlist, playlists in the order
  /// their oldest queued add was made.
  ///
  /// Orphans are swept here rather than returned: this is the one place every
  /// reader passes through.
  public func pendingBatches(for account: Account) -> [PendingPlaylistSongAddBatch] {
    let pendingAdds = sweepOrphans(in: library.getPendingPlaylistSongAdds(for: account))
    return groupIntoBatches(pendingAdds)
  }

  /// Pending work for one playlist, oldest first. Used by the reconciliation
  /// guard that runs after every per-playlist fetch.
  public func pendingAdds(for playlist: Playlist) -> [PendingPlaylistSongAdd] {
    sweepOrphans(in: library.getPendingPlaylistSongAdds(for: playlist))
  }

  public func pendingAddCount(for account: Account) -> Int {
    library.getPendingPlaylistSongAdds(for: account).count
  }

  public var hasAnyPendingAdds: Bool {
    !library.getAllPendingPlaylistSongAdds().isEmpty
  }

  // MARK: - Resolving outcomes

  /// The upload landed, or the server permanently refused it — either way these
  /// adds have had their answer and must not be retried.
  public func delete(_ pendingAdds: [PendingPlaylistSongAdd]) {
    guard !pendingAdds.isEmpty else { return }
    for pendingAdd in pendingAdds {
      library.deletePendingPlaylistSongAdd(pendingAdd)
    }
    library.saveContext()
  }

  /// A transient failure: keep the adds, remember why, and count the attempt.
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
    os_log(
      "%i playlist song add(s) stay queued after a transient failure and will be retried",
      log: log,
      type: .info,
      pendingAdds.count
    )
  }

  // MARK: - Internals

  private func groupIntoBatches(_ pendingAdds: [PendingPlaylistSongAdd])
    -> [PendingPlaylistSongAddBatch] {
    var batchOrder = [NSManagedObjectID]()
    var addsByPlaylistObjectId = [NSManagedObjectID: [PendingPlaylistSongAdd]]()
    var playlistsByObjectId = [NSManagedObjectID: Playlist]()

    for pendingAdd in pendingAdds {
      guard let playlist = pendingAdd.playlist, pendingAdd.song != nil else { continue }
      let playlistObjectId = playlist.managedObject.objectID
      if addsByPlaylistObjectId[playlistObjectId] == nil {
        batchOrder.append(playlistObjectId)
        playlistsByObjectId[playlistObjectId] = playlist
      }
      addsByPlaylistObjectId[playlistObjectId, default: []].append(pendingAdd)
    }

    return batchOrder.compactMap { playlistObjectId in
      guard let playlist = playlistsByObjectId[playlistObjectId],
            let pendingAdds = addsByPlaylistObjectId[playlistObjectId]
      else { return nil }
      return PendingPlaylistSongAddBatch(
        playlist: playlist,
        songs: pendingAdds.compactMap(\.song),
        pendingAdds: pendingAdds
      )
    }
  }

  /// Drop the adds whose playlist, song or account no longer exists locally and
  /// return the rest.
  private func sweepOrphans(in pendingAdds: [PendingPlaylistSongAdd])
    -> [PendingPlaylistSongAdd] {
    let orphanedAdds = pendingAdds.filter(\.isOrphaned)
    guard !orphanedAdds.isEmpty else { return pendingAdds }
    os_log(
      "Sweeping %i orphaned pending playlist song add(s): the playlist or song is gone locally",
      log: log,
      type: .info,
      orphanedAdds.count
    )
    delete(orphanedAdds)
    return pendingAdds.filter { !orphanedAdds.contains($0) }
  }
}
