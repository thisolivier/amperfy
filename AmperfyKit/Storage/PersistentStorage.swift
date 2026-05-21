//
//  PersistentStorage.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

// MARK: - CoreDataCompanion

public class CoreDataCompanion {
  public let context: NSManagedObjectContext
  public let library: LibraryStorage

  init(context: NSManagedObjectContext) {
    self.context = context
    self.library = LibraryStorage(context: context)
  }

  public func saveContext() {
    library.saveContext()
  }

  public func perform(body: @escaping (_ asyncCompanion: CoreDataCompanion) -> ()) {
    context.performAndWait {
      body(self)
      library.saveContext()
    }
  }
}

// MARK: - AsyncCoreDataAccessWrapper

public actor AsyncCoreDataAccessWrapper {
  let persistentContainer: NSPersistentContainer

  init(persistentContainer: NSPersistentContainer) {
    self.persistentContainer = persistentContainer
  }

  public func perform(
    body: @escaping @Sendable (_ asyncCompanion: CoreDataCompanion) throws
      -> ()
  ) async throws {
    let context = persistentContainer.newBackgroundContext()
    NSPersistentContainer.configureContext(context)

    await context.perform {
      let library = LibraryStorage(context: context)
      let asyncCompanion = CoreDataCompanion(context: context)
      do {
        try body(asyncCompanion)
        library.saveContext()
      } catch {
        library.saveContext()
      }
    }
  }

  public func performAndGet<T>(
    body: @escaping @Sendable (_ asyncCompanion: CoreDataCompanion) throws
      -> T
  ) async throws
    -> T where T: Sendable {
    let context = persistentContainer.newBackgroundContext()
    NSPersistentContainer.configureContext(context)

    let syncRequestedValue = try await context.perform {
      let asyncCompanion = CoreDataCompanion(context: context)
      do {
        let asyncRequestedValue = try body(asyncCompanion)
        asyncCompanion.saveContext()
        return asyncRequestedValue
      } catch {
        asyncCompanion.saveContext()
        throw error
      }
    }
    return syncRequestedValue
  }
}

// MARK: - PersistentStorage

public class PersistentStorage {
  public enum UserDefaultsKey: String {
    case SettingsApp = "settings.app"
    case SettingsUser = "settings.user"
    case SettingsAccount = "settings.account"

    // Deprecated Settings
    case ServerUrl = "serverUrl"
    case AlternativeServerUrls = "alternativeServerUrls"
    case Username = "username"
    case Password = "password"
    case BackendApi = "backendApi"
    case LibraryIsSynced = "libraryIsSynced"
    case InitialSyncCompletionStatus = "initialSyncCompletionStatus"
    case ArtworkDownloadSetting = "artworkDownloadSetting"
    case ArtworkDisplayPreference = "artworkDisplayPreference"
    case SleepTimerInterval = "sleepTimerInterval" // not used anymore !!!
    case ScreenLockPreventionPreference = "screenLockPreventionPreference"
    case StreamingMaxBitrateWifiPreference = "streamingMaxBitrateWifiPreference"
    case StreamingMaxBitrateCellularPreference = "streamingMaxBitrateCellularPreference"
    case StreamingFormatPreference =
      "streamingFormatPreference" // deprecated: use Wifi and Cellular instead
    case StreamingFormatWifiPreference = "streamingFormatWifiPreference"
    case StreamingFormatCellularPreference = "streamingFormatCellularPreference"
    case CacheTranscodingFormatPreference = "cacheTranscodingFormatPreference"
    case CacheLimit = "cacheLimitInBytes" // limit in byte
    case PlayerVolume = "playerVolume"
    case ShowDetailedInfo = "showDetailedInfo"
    case ShowSongDuration = "showSongDuration"
    case ShowAlbumDuration = "showAlbumDuration"
    case ShowArtistDuration = "showArtistDuration"
    case PlayerShuffleButtonEnabled = "enablePlayerShuffleButton"
    case ShowMusicPlayerSkipButtons = "showMusicPlayerSkipButtons"
    case AlwaysHidePlayerLyricsButton = "alwaysHidePlayerLyricsButton"
    case IsLyricsSmoothScrolling = "isLyricsSmoothScrolling"
    case AppearanceMode = "appearanceMode"
    case SongActionOnTab = "songActionOnTab"
    case LibraryDisplaySettings = "libraryDisplaySettings"
    case SwipeLeadingActionSettings = "swipeLeadingActionSettings"
    case SwipeTrailingActionSettings = "swipeTrailingActionSettings"
    case PlaylistsSortSetting = "playlistsSortSetting"
    case ArtistsSortSetting = "artistsSortSetting"
    case AlbumsSortSetting = "albumsSortSetting"
    case SongsSortSetting = "songsSortSetting"
    case FavoriteSongSortSetting = "favoriteSongSortSetting"
    case ArtistsFilterSetting = "artistsFilterSetting"
    case AlbumsDisplayStyleSetting = "albumsDisplayStyleSetting"
    case AlbumsGridSizeSetting = "albumsGridSizeSetting"
    case PodcastsShowSetting = "podcastsShowSetting"
    case PlayerDisplayStyle = "playerDisplayStyle"
    case IsPlayerLyricsDisplayed = "isPlayerLyricsDisplayed" // not used anymore
    case IsPlayerVisualizerDisplayed = "isPlayerVisualizerDisplayed"
    case IsOfflineMode = "isOfflineMode"
    case IsAutoDownloadLatestSongsActive = "isAutoDownloadLatestSongsActive"
    case IsAutoDownloadLatestPodcastEpisodesActive = "isAutoDownloadLatestPodcastEpisodesActive"
    case IsScrobbleStreamedItems = "isScrobbleStreamedItems"
    case IsPlaybackStartOnlyOnPlay = "isPlaybackStartOnlyOnPlay"
    case LibrarySyncVersion = "librarySyncVersion"
    case IsHapticsEnabled = "isHapticsEnabled"
    case HomeSections = "homeSections"
    case LibrarySyncInfoReadByUser = "librarySyncInfoReadByUser"
    case ThemePreference = "themePreference"
    case IsEqualizerEnabled = "isEqualizerEnabled"
    case EqualizerSettings = "equalizerSettings"
    case ActiveEqualizerSetting = "activeEqualizerSetting"
    case IsReplayGainEnabled = "isReplayGainEnabled"
  }

  private var coreDataManager: CoreDataManagable

  init(coreDataManager: CoreDataManagable) {
    self.coreDataManager = coreDataManager
  }

  // deprecated
  public var legacySettings = LegacySettings()

  public var settings = AmperfySettings()

  @MainActor
  public lazy var main: CoreDataCompanion = {
    CoreDataCompanion(context: coreDataManager.context)
  }()

  public var async: AsyncCoreDataAccessWrapper {
    AsyncCoreDataAccessWrapper(persistentContainer: coreDataManager.persistentContainer)
  }

  /// Creates a fresh background context that reads committed data directly from SQLite.
  public func newBackgroundContext() -> NSManagedObjectContext {
    coreDataManager.persistentContainer.newBackgroundContext()
  }
}

// MARK: - CoreDataManagable

protocol CoreDataManagable {
  var persistentContainer: NSPersistentContainer { get }
  @MainActor
  var context: NSManagedObjectContext { get }
}

// MARK: - CoreDataConfiguration

public struct CoreDataConfiguration: Sendable {
  public let containerGroupID: String?
  public let readOnly: Bool

  public init(containerGroupID: String? = nil, readOnly: Bool = false) {
    self.containerGroupID = containerGroupID
    self.readOnly = readOnly
  }

  public static let `default` = CoreDataConfiguration()

  /// Shared container URL for the given App Group identifier.
  public var sharedContainerURL: URL? {
    guard let groupID = containerGroupID else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
  }

  /// Full URL for the SQLite store inside the shared container.
  public var sharedStoreURL: URL? {
    sharedContainerURL?.appendingPathComponent("Amperfy.sqlite")
  }
}

// MARK: - CoreDataPersistentManager

public class CoreDataPersistentManager: CoreDataManagable {
  nonisolated(unsafe) public static let managedObjectModel: NSManagedObjectModel =
    .mergedModel(from: [Bundle.main])!

  public let configuration: CoreDataConfiguration

  public init(configuration: CoreDataConfiguration = .default) {
    self.configuration = configuration
  }

  lazy var persistentContainer: NSPersistentContainer = {
    let container = NSPersistentContainer(
      name: "Amperfy",
      managedObjectModel: Self.managedObjectModel
    )

    // Use shared container URL if an App Group is configured
    if let sharedStoreURL = configuration.sharedStoreURL {
      let storeDescription = NSPersistentStoreDescription(url: sharedStoreURL)
      storeDescription.type = NSSQLiteStoreType

      if configuration.readOnly {
        storeDescription.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        // Read-only consumers should never migrate the store
        storeDescription.shouldInferMappingModelAutomatically = false
        storeDescription.shouldMigrateStoreAutomatically = false
      } else {
        storeDescription.shouldInferMappingModelAutomatically = false
        storeDescription.shouldMigrateStoreAutomatically = false
      }

      container.persistentStoreDescriptions = [storeDescription]
    } else {
      // Default location — configure existing description
      let description = container.persistentStoreDescriptions.first
      description?.shouldInferMappingModelAutomatically = false
      description?.shouldMigrateStoreAutomatically = false
      description?.type = NSSQLiteStoreType
    }

    guard let storeURL = container.persistentStoreDescriptions.first?.url else {
      fatalError("persistentContainer was not set up properly")
    }

    // Only run migration for read-write mode
    if !configuration.readOnly {
      let migrator = CoreDataMigrator()
      if migrator.requiresMigration(at: storeURL, toVersion: CoreDataMigrationVersion.current) {
        migrator.migrateStore(at: storeURL, toVersion: CoreDataMigrationVersion.current)
      }
    }

    container.loadPersistentStores(completionHandler: { storeDescription, error in
      if let error = error as NSError? {
        fatalError("Unresolved error \(error), \(error.userInfo)")
      }
    })

    return container
  }()

  @MainActor
  lazy var context: NSManagedObjectContext = {
    NSPersistentContainer.configureContext(persistentContainer.viewContext)
    return persistentContainer.viewContext
  }()
}

extension NSPersistentContainer {
  static fileprivate func configureContext(_ contextToConfigure: NSManagedObjectContext) {
    contextToConfigure.automaticallyMergesChangesFromParent = true
    contextToConfigure.retainsRegisteredObjects = true
    contextToConfigure
      .mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
  }
}
