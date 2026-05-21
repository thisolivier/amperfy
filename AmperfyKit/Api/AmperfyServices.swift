//  AmperfyServices.swift
//  AmperfyKit

import Foundation
import os.log

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
}
