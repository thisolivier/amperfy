//
//  AlbumScanWorker.swift
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

// MARK: - AlbumScanWorker

/// Phase 1 worker: syncs songs for albums that have no synced songs yet.
///
/// Extracts the per-album sync loop from `BackgroundLibrarySyncer.syncAlbumSongsInBackground()`
/// and conforms it to `BackgroundTaskWorker` so the runner can manage its lifecycle.
///
/// Core Data note: Album MOs are resolved via `mainStorage.context` (the main context),
/// which mirrors the original BackgroundSyncOperation pattern. The sync network call
/// is awaited from a background-thread async Task so the main thread is not blocked.
public final class AlbumScanWorker: BackgroundTaskWorker, @unchecked Sendable {
  public var kind: TaskKind { .albumScan }

  private let storage: AsyncCoreDataAccessWrapper
  private let mainStorage: CoreDataCompanion
  private let librarySyncer: LibrarySyncer
  private let settings: AmperfySettings
  private let networkMonitor: NetworkMonitorFacade
  private let eventLogger: EventLogger

  private let log = OSLog(subsystem: "Amperfy", category: "AlbumScanWorker")

  @MainActor
  public init(
    storage: AsyncCoreDataAccessWrapper,
    mainStorage: CoreDataCompanion,
    librarySyncer: LibrarySyncer,
    settings: AmperfySettings,
    networkMonitor: NetworkMonitorFacade,
    eventLogger: EventLogger
  ) {
    self.storage = storage
    self.mainStorage = mainStorage
    self.librarySyncer = librarySyncer
    self.settings = settings
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
  }

  public func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws {
    os_log("AlbumScanWorker: starting Phase 1 album scan", log: log, type: .info)
    MemoryReporter.logMemory(label: "album-scan-start")

    // Collect albums that need syncing via a background Core Data context.
    let albumObjectIDs: [NSManagedObjectID] = try await storage.performAndGet { asyncCompanion in
      asyncCompanion.library.getAlbumWithoutSyncedSongs()
        .map { $0.managedObject.objectID }
    }

    let totalAlbums = albumObjectIDs.count
    os_log(
      "AlbumScanWorker: %d albums to scan",
      log: log,
      type: .info,
      totalAlbums
    )
    context.reportProgress(.progress(done: 0, total: totalAlbums))

    var completedAlbums = 0
    for albumObjectID in albumObjectIDs {
      guard !context.isCancelled.wrappedValue else {
        os_log("AlbumScanWorker: cancelled mid-scan", log: log, type: .info)
        return
      }
      guard settings.user.isOnlineMode, networkMonitor.isConnectedToNetwork else {
        os_log("AlbumScanWorker: offline, stopping scan", log: log, type: .info)
        return
      }

      await syncSingleAlbum(objectID: albumObjectID)

      completedAlbums += 1
      context.reportProgress(.progress(done: completedAlbums, total: totalAlbums))
    }

    MemoryReporter.logMemory(label: "album-scan-done")
    os_log("AlbumScanWorker: Phase 1 complete (%d albums)", log: log, type: .info, completedAlbums)
  }

  /// Sync a single album identified by its Core Data object ID.
  /// Resolves the MO on the main context (same pattern as the pre-runner
  /// BackgroundSyncOperation), then performs the network call asynchronously.
  @MainActor
  private func syncSingleAlbum(objectID: NSManagedObjectID) async {
    let albumMO = mainStorage.context.object(with: objectID) as! AlbumMO
    let album = Album(managedObject: albumMO)
    do {
      try await librarySyncer.sync(album: album)
    } catch {
      eventLogger.report(
        topic: "Album Background Sync",
        error: error,
        displayPopup: false
      )
      album.isSongsMetaDataSynced = true
    }
  }
}
