//
//  BackgroundLibrarySyncer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 12.04.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

// MARK: - BackgroundSyncOperation

public class BackgroundSyncOperation: AsyncOperation, @unchecked Sendable {
  private let completeBlock: VoidAsyncClosure

  public init(completeBlock: @escaping VoidAsyncClosure) {
    self.completeBlock = completeBlock
  }

  override public func main() {
    Task {
      await self.completeBlock()
      finish()
    }
  }
}

// MARK: - BackgroundLibrarySyncer

public final class BackgroundLibrarySyncer: AbstractBackgroundLibrarySyncer, Sendable {
  private let storage: AsyncCoreDataAccessWrapper
  @MainActor
  private let mainStorage: CoreDataCompanion
  private let settings: AmperfySettings
  private let networkMonitor: NetworkMonitorFacade
  private let librarySyncer: LibrarySyncer
  @MainActor
  private let playableDownloadManager: DownloadManageable
  @MainActor
  private let autoDownloadLibrarySyncer: AutoDownloadLibrarySyncer
  private let eventLogger: EventLogger
  @MainActor
  private let account: Account

  private let log = OSLog(subsystem: "Amperfy", category: "BackgroundLibrarySyncer")
  private let isRunning = Atomic<Bool>(wrappedValue: false)
  private let isCurrentlyActive = Atomic<Bool>(wrappedValue: false)
  private let backgroundTask = Atomic<Task<(), Never>?>(wrappedValue: nil)
  private let taskQueue: OperationQueue

  @MainActor
  init(
    storage: AsyncCoreDataAccessWrapper,
    mainStorage: CoreDataCompanion,
    settings: AmperfySettings,
    networkMonitor: NetworkMonitorFacade,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable,
    autoDownloadLibrarySyncer: AutoDownloadLibrarySyncer,
    eventLogger: EventLogger,
    account: Account
  ) {
    self.storage = storage
    self.mainStorage = mainStorage
    self.settings = settings
    self.networkMonitor = networkMonitor
    self.librarySyncer = librarySyncer
    self.playableDownloadManager = playableDownloadManager
    self.autoDownloadLibrarySyncer = autoDownloadLibrarySyncer
    self.eventLogger = eventLogger
    self.account = account
    self.taskQueue = OperationQueue()
    taskQueue.maxConcurrentOperationCount = 1
  }

  var isActive: Bool { isCurrentlyActive.wrappedValue }

  public func start() {
    isRunning.wrappedValue = true
    if !isCurrentlyActive.wrappedValue {
      isCurrentlyActive.wrappedValue = true
      syncAlbumSongsInBackground()
    }
  }

  public func stop() {
    isRunning.wrappedValue = false
    taskQueue.cancelAllOperations()
    addOperationsEndMessage()
  }

  private func syncAlbumSongsInBackground() {
    backgroundTask.wrappedValue = Task {
      os_log("start", log: self.log, type: .info)
      MemoryReporter.logMemory(label: "sync start")

      if self.isRunning.wrappedValue, self.settings.user.isOnlineMode,
         self.networkMonitor.isConnectedToNetwork {
        do {
          try await autoDownloadLibrarySyncer
            .syncNewestLibraryElements(offset: 0, count: AmperKit.newestElementsFetchCount)
        } catch {
          await self.eventLogger.report(
            topic: "Latest Library Elements Background Sync",
            error: error,
            displayPopup: false
          )
        }
      }

      try? await storage.perform { asyncCompanion in
        let albumsToSync = asyncCompanion.library.getAlbumWithoutSyncedSongs()

        for albumToSync in albumsToSync {
          let albumObjectID = albumToSync.managedObject.objectID
          let asyncOperation = BackgroundSyncOperation {
            guard !Task.isCancelled, self.isRunning.wrappedValue, self.settings.user.isOnlineMode,
                  self.networkMonitor.isConnectedToNetwork else { return }
            let albumMO = self.mainStorage.context.object(with: albumObjectID) as! AlbumMO
            let album = Album(managedObject: albumMO)
            do {
              try await self.librarySyncer.sync(album: album)
            } catch {
              self.eventLogger.report(
                topic: "Album Background Sync",
                error: error,
                displayPopup: false
              )
              album.isSongsMetaDataSynced = true
            }
          }
          self.taskQueue.addOperation(asyncOperation)
        }
      }

      MemoryReporter.logMemory(label: "after album song sync")

      // Phase 2: Playlist item sync + adjacency recomputation DISABLED (Build 30 hotfix)
      // These operations accumulate Core Data objects in memory (~2 GB on large libraries)
      // causing Jetsam kills on physical devices. Will be re-enabled with batched/reset approach.
      // await self.queuePlaylistItemSyncs()

      self.addOperationsEndMessage()
    }
  }

  private func queuePlaylistItemSyncs() async {
    // Fetch playlist data on the main actor (required for mainStorage access),
    // but capture only the lightweight IDs/objectIDs so we release the main thread quickly.
    let playlistInfo: [(id: String, objectID: NSManagedObjectID)] = await MainActor.run {
      let tracker = PlaylistItemsSyncTracker.shared
      let allPlaylists = mainStorage.library.getPlaylists(
        for: account,
        areSystemPlaylistsIncluded: false
      )
      let unsynced = allPlaylists.filter { !tracker.isSynced($0.id) }
      os_log(
        "Playlist item sync: %d unsynced of %d total",
        log: self.log,
        type: .info,
        unsynced.count,
        allPlaylists.count
      )
      return unsynced.map { (id: $0.id, objectID: $0.managedObject.objectID) }
    }

    guard !playlistInfo.isEmpty else { return }

    let tracker = PlaylistItemsSyncTracker.shared
    for info in playlistInfo {
      let playlistId = info.id
      let playlistObjectID = info.objectID
      let asyncOperation = BackgroundSyncOperation {
        guard !Task.isCancelled, self.isRunning.wrappedValue, self.settings.user.isOnlineMode,
              self.networkMonitor.isConnectedToNetwork else { return }
        let playlistMO = self.mainStorage.context.object(with: playlistObjectID) as! PlaylistMO
        let playlistToSync = Playlist(library: self.mainStorage.library, managedObject: playlistMO)
        do {
          try await self.librarySyncer.syncDown(playlist: playlistToSync)
          tracker.markSynced(playlistId)
        } catch {
          self.eventLogger.report(
            topic: "Playlist Items Background Sync",
            error: error,
            displayPopup: false
          )
        }
      }
      taskQueue.addOperation(asyncOperation)
    }

    // After all playlist items are synced, recompute track adjacency
    let adjacencyOperation = BackgroundSyncOperation {
      guard self.isRunning.wrappedValue else { return }
      os_log("Playlist item sync complete, recomputing track adjacency", log: self.log, type: .info)
      DefaultTrackAdjacencyService.shared.invalidate()
      DefaultTrackAdjacencyService.shared.computeIfNeeded()
    }
    taskQueue.addOperation(adjacencyOperation)
  }

  func addOperationsEndMessage() {
    taskQueue.addBarrierBlock {
      self.isRunning.wrappedValue = false
      os_log("stopped", log: self.log, type: .info)
    }
  }
}
