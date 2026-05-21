//  AmperfyServices.swift
//  AmperfyKit

import Foundation
import os.log

// MARK: - AmperfyServices

/// Container for all AmperfyKit services, constructed once at app launch.
/// Replaces direct `AmperKit.shared` access in the app target.
public struct AmperfyServices {
  // Protocol-backed services
  public let library: LibraryProvider
  public let settings: SettingsProvider
  public let player: PlayerFacade
  public let sync: SyncCoordinator
  public let downloads: DownloadCoordinator
  public let folders: FolderProvider
  public let networkMonitor: NetworkMonitorFacade

  // Direct references for things not yet protocolized
  public let storage: PersistentStorage
  public let eventLogger: EventLogger
  public let libraryUpdater: LibraryUpdater
  public let userStatistics: UserStatistics
  public let localNotificationManager: LocalNotificationManager
  public let notificationHandler: EventNotificationHandler
  public let log: OSLog
  public let threadPerformanceMonitor: ThreadPerformanceMonitor

  /// Creates a read-only services container for companion apps (e.g. Graph Explorer).
  /// Player, sync, downloads, and folders use no-op implementations.
  @MainActor
  public static func createReadOnly(containerGroup: String) -> AmperfyServices {
    let configuration = CoreDataConfiguration(
      containerGroupID: containerGroup,
      readOnly: true
    )
    let coreDataManager = CoreDataPersistentManager(configuration: configuration)
    let storage = PersistentStorage(coreDataManager: coreDataManager)
    let userStatistics = storage.main.library.getUserStatistics(
      appVersion: AmperKit.version
    )

    return AmperfyServices(
      library: LibraryProviderImpl(libraryStorage: storage.main.library),
      settings: SettingsProviderImpl(storage: storage),
      player: NoOpPlayerFacade(),
      sync: NoOpSyncCoordinator(),
      downloads: NoOpDownloadCoordinator(),
      folders: NoOpFolderProvider(),
      networkMonitor: NoOpNetworkMonitor(),
      storage: storage,
      eventLogger: EventLogger(storage: storage),
      libraryUpdater: LibraryUpdater(storage: storage),
      userStatistics: userStatistics,
      localNotificationManager: LocalNotificationManager(
        userStatistics: userStatistics,
        storage: storage
      ),
      notificationHandler: EventNotificationHandler(),
      log: OSLog(subsystem: "Amperfy", category: "ReadOnly"),
      threadPerformanceMonitor: ThreadPerformanceObserver.shared
    )
  }
}

// MARK: - ReadOnlyAmperfyAccess

/// Lightweight read-only access to AmperfyKit's library and settings via the shared App Group
/// container. Designed for companion apps (e.g. Graph Explorer) that need to read but never
/// write to the Amperfy data store.
public struct ReadOnlyAmperfyAccess {
  public let library: LibraryProvider
  public let settings: SettingsProvider
  public let storage: PersistentStorage

  /// Creates a read-only accessor backed by the shared App Group container.
  ///
  /// - Parameter containerGroupID: The App Group identifier (e.g. `group.com.amperfy.shared`).
  @MainActor
  public static func create(containerGroupID: String) -> ReadOnlyAmperfyAccess {
    let configuration = CoreDataConfiguration(containerGroupID: containerGroupID, readOnly: true)
    let coreDataManager = CoreDataPersistentManager(configuration: configuration)
    let persistentStorage = PersistentStorage(coreDataManager: coreDataManager)

    return ReadOnlyAmperfyAccess(
      library: LibraryProviderImpl(libraryStorage: persistentStorage.main.library),
      settings: SettingsProviderImpl(storage: persistentStorage),
      storage: persistentStorage
    )
  }
}
