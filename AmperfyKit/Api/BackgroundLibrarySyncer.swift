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

/// Thin entry-point for the background sync lifecycle.
///
/// After PR 19e, this class is responsible only for:
/// 1. Triggering the newest-elements pre-sync (unchanged from original)
/// 2. Enqueueing the Phase 1 album scan and Phase 2 playlist sync tasks
///    through `BackgroundTaskRunner` (which manages all status/cancel logic)
///
/// The direct Phase 1 loop and queuePlaylistItemSyncs() have been removed —
/// all background task execution now goes through the unified runner.
public final class BackgroundLibrarySyncer: AbstractBackgroundLibrarySyncer, Sendable {
  private let settings: AmperfySettings
  private let networkMonitor: NetworkMonitorFacade
  @MainActor
  private let playableDownloadManager: DownloadManageable
  @MainActor
  private let autoDownloadLibrarySyncer: AutoDownloadLibrarySyncer
  private let eventLogger: EventLogger

  private let log = OSLog(subsystem: "Amperfy", category: "BackgroundLibrarySyncer")
  private let isRunning = Atomic<Bool>(wrappedValue: false)
  private let isCurrentlyActive = Atomic<Bool>(wrappedValue: false)
  private let backgroundTask = Atomic<Task<(), Never>?>(wrappedValue: nil)

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
    self.settings = settings
    self.networkMonitor = networkMonitor
    self.playableDownloadManager = playableDownloadManager
    self.autoDownloadLibrarySyncer = autoDownloadLibrarySyncer
    self.eventLogger = eventLogger
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
    BackgroundTaskRunner.shared.cancelAll()
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

      // Phase 1 (album scan) and Phase 2 (playlist sync, gated behind phase2Enabled)
      // both run through the unified runner. The runner handles status transitions,
      // cancellation, watchdogs, and memory-safe batch resets for Phase 2.
      BackgroundTaskRunner.shared.enqueue(
        TaskDescriptor(kind: .albumScan, triggerReason: .scheduled)
      )
      BackgroundTaskRunner.shared.enqueue(
        TaskDescriptor(kind: .playlistItemSync, triggerReason: .scheduled)
      )
    }
  }
}
