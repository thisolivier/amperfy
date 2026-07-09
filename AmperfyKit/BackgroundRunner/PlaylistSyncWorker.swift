//
//  PlaylistSyncWorker.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 19 — Background task runner).
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

// MARK: - PlaylistSyncWorker

/// Phase 2 worker: syncs playlist items from the server using batched Core Data
/// context resets to prevent the unbounded `PlaylistItemMO` accumulation that
/// caused the Build 30 Jetsam kill (~2.1 GB peak).
///
/// Every `contextResetBatchSize` playlists, the main context performs a reset
/// to release accumulated PlaylistItemMO objects and keep memory bounded.
///
/// On completion, auto-enqueues an `.adjacencyCompute` task so that newly-synced
/// playlist items are reflected in the adjacency scores.
public final class PlaylistSyncWorker: BackgroundTaskWorker, @unchecked Sendable {
  public var kind: TaskKind { .playlistItemSync }

  /// Number of playlists to sync between main-context resets.
  /// Chosen conservatively to bound memory growth across large libraries.
  private static let contextResetBatchSize = 5

  private let mainStorage: CoreDataCompanion
  private let librarySyncer: LibrarySyncer
  private let settings: AmperfySettings
  private let networkMonitor: NetworkMonitorFacade
  private let eventLogger: EventLogger
  /// Captured on the main actor at init time. Used to fetch playlist IDs.
  private let accountObjectID: NSManagedObjectID

  private let log = OSLog(subsystem: "Amperfy", category: "PlaylistSyncWorker")

  @MainActor
  public init(
    mainStorage: CoreDataCompanion,
    librarySyncer: LibrarySyncer,
    settings: AmperfySettings,
    networkMonitor: NetworkMonitorFacade,
    eventLogger: EventLogger,
    account: Account
  ) {
    self.mainStorage = mainStorage
    self.librarySyncer = librarySyncer
    self.settings = settings
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
    self.accountObjectID = account.managedObject.objectID
  }

  public func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws {
    os_log("PlaylistSyncWorker: starting Phase 2 playlist sync", log: log, type: .info)
    MemoryReporter.logMemory(label: "playlist-sync-start")

    // Fetch unsynced playlist IDs on the main actor. We only capture lightweight
    // value types (id + objectID) so the main thread is released immediately.
    let unsyncedPlaylistInfo = await fetchUnsyncedPlaylistInfo()

    guard !unsyncedPlaylistInfo.isEmpty else {
      os_log(
        "PlaylistSyncWorker: all playlists already synced, nothing to do",
        log: log,
        type: .info
      )
      return
    }

    let tracker = PlaylistItemsSyncTracker.shared
    let totalPlaylists = unsyncedPlaylistInfo.count
    var completedPlaylists = 0
    context.reportProgress(.progress(done: 0, total: totalPlaylists))

    for (batchStart, playlistInfo) in unsyncedPlaylistInfo.enumerated() {
      guard !context.isCancelled.wrappedValue else {
        os_log("PlaylistSyncWorker: cancelled mid-sync", log: log, type: .info)
        return
      }
      guard settings.user.isOnlineMode, networkMonitor.isConnectedToNetwork else {
        os_log("PlaylistSyncWorker: offline, stopping sync", log: log, type: .info)
        return
      }

      await syncSinglePlaylist(
        objectID: playlistInfo.objectID,
        playlistId: playlistInfo.id,
        tracker: tracker
      )

      completedPlaylists += 1
      context.reportProgress(.progress(done: completedPlaylists, total: totalPlaylists))

      // CRITICAL: reset the main context every N playlists to release
      // accumulated PlaylistItemMO objects. This is the Build 30 memory fix.
      let isLastItem = completedPlaylists == totalPlaylists
      let isBatchBoundary = batchStart > 0
        && (batchStart + 1) % Self.contextResetBatchSize == 0
      if isBatchBoundary, !isLastItem {
        await resetMainContext()
        MemoryReporter.logMemory(label: "playlist-sync-batch-reset-\(completedPlaylists)")
        os_log(
          "PlaylistSyncWorker: context reset after %d playlists",
          log: log,
          type: .info,
          completedPlaylists
        )
      }
    }

    MemoryReporter.logMemory(label: "playlist-sync-done")
    os_log(
      "PlaylistSyncWorker: Phase 2 complete (%d playlists)",
      log: log,
      type: .info,
      completedPlaylists
    )

    // Auto-kick adjacency recompute now that playlist items are up to date.
    BackgroundTaskRunner.shared.enqueue(
      TaskDescriptor(kind: .adjacencyCompute, triggerReason: .invalidation)
    )
  }

  // MARK: - MainActor helpers

  /// Fetch all unsynced playlist (id, objectID) pairs from the main context.
  @MainActor
  private func fetchUnsyncedPlaylistInfo() -> [(id: String, objectID: NSManagedObjectID)] {
    let tracker = PlaylistItemsSyncTracker.shared
    let accountMO = mainStorage.context.object(with: accountObjectID) as! AccountMO
    let account = Account(managedObject: accountMO)
    let allPlaylists = mainStorage.library.getPlaylists(
      for: account,
      areSystemPlaylistsIncluded: false
    )
    // Invalidate any previously-synced playlist whose server-reported song count
    // no longer matches its locally-stored items (edited-after-sync). Those fall
    // back into the unsynced set below and get their items re-fetched.
    for playlist in allPlaylists {
      tracker.reconcile(
        playlistId: playlist.id,
        localItemCount: playlist.localItemCount,
        remoteSongCount: playlist.remoteSongCount
      )
    }
    let unsyncedPlaylists = allPlaylists.filter { !tracker.isSynced($0.id) }
    os_log(
      "PlaylistSyncWorker: %d unsynced of %d total playlists",
      log: log,
      type: .info,
      unsyncedPlaylists.count,
      allPlaylists.count
    )
    return unsyncedPlaylists.map { (id: $0.id, objectID: $0.managedObject.objectID) }
  }

  /// Sync a single playlist identified by its Core Data object ID.
  /// Resolves the MO on the main context (same pattern as the pre-runner lazy-sync paths).
  @MainActor
  private func syncSinglePlaylist(
    objectID: NSManagedObjectID,
    playlistId: String,
    tracker: PlaylistItemsSyncTracker
  ) async {
    let playlistMO = mainStorage.context.object(with: objectID) as! PlaylistMO
    let playlist = Playlist(library: mainStorage.library, managedObject: playlistMO)
    do {
      try await librarySyncer.syncDown(playlist: playlist)
      tracker.markSynced(playlistId)
    } catch {
      eventLogger.report(
        topic: "Playlist Items Background Sync",
        error: error,
        displayPopup: false
      )
    }
  }

  /// Reset the main Core Data context to release accumulated PlaylistItemMO objects.
  @MainActor
  private func resetMainContext() {
    mainStorage.context.reset()
  }
}
