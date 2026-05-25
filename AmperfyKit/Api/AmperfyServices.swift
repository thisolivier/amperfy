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

// MARK: - StandaloneAmperfyKit

/// Self-contained AmperfyKit access for companion apps that need login, sync, and query
/// capabilities using their own independent CoreData store (no App Group required).
/// Designed for Graph Explorer's standalone mode.
public final class StandaloneAmperfyKit: @unchecked Sendable {
  public let storage: PersistentStorage
  public let library: LibraryProvider
  public let eventLogger: EventLogger
  public let notificationHandler: EventNotificationHandler

  private let networkMonitor: NetworkMonitorFacade
  private let performanceMonitor: ThreadPerformanceMonitor

  /// The BackendProxy for the current account, created after `prepareForLogin()`.
  private var _backendProxy: BackendProxy?

  /// The library syncer, created after successful login.
  private var _librarySyncer: LibrarySyncer?

  /// The account entity, created after `prepareForLogin()`.
  private var _account: Account?

  public var account: Account? { _account }

  @MainActor
  public static func create() -> StandaloneAmperfyKit {
    let configuration = CoreDataConfiguration()  // default: no container group, read-write
    let coreDataManager = CoreDataPersistentManager(configuration: configuration)
    let persistentStorage = PersistentStorage(coreDataManager: coreDataManager)

    return StandaloneAmperfyKit(storage: persistentStorage)
  }

  @MainActor
  private init(storage: PersistentStorage) {
    self.storage = storage
    self.library = LibraryProviderImpl(libraryStorage: storage.main.library)
    self.eventLogger = EventLogger(storage: storage)
    self.notificationHandler = EventNotificationHandler()
    self.networkMonitor = AlwaysConnectedNetworkMonitor()
    self.performanceMonitor = ThreadPerformanceObserver.shared
  }

  /// Returns true if stored credentials exist from a prior login.
  public var hasStoredCredentials: Bool {
    storage.settings.accounts.activeSetting.read.loginCredentials != nil
  }

  /// Returns the active account from the library, if one exists from a prior session.
  @MainActor
  public func restoreExistingAccount() -> Account? {
    guard let credentials = storage.settings.accounts.activeSetting.read.loginCredentials else {
      return nil
    }
    let accountInfo = Account.createInfo(credentials: credentials)
    let account = library.getAccount(info: accountInfo)

    // Set up backend proxy with stored credentials
    let backendProxy = BackendProxy(
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger,
      settings: storage.settings
    )
    backendProxy.initialize()
    backendProxy.selectedApi = credentials.backendApi
    backendProxy.provideCredentials(credentials: credentials)

    _backendProxy = backendProxy
    _account = account
    _librarySyncer = LibrarySyncerProxy(
      backendApi: backendProxy,
      account: account,
      storage: storage
    )

    return account
  }

  /// Logs in to a server and stores credentials. Returns the detected API type.
  @MainActor
  public func login(
    serverUrl: String,
    username: String,
    password: String
  ) async throws -> BackenApiType {
    var credentials = LoginCredentials(
      serverUrl: serverUrl,
      username: username,
      password: password
    )
    let accountInfo = Account.createInfo(credentials: credentials)

    let backendProxy = BackendProxy(
      networkMonitor: networkMonitor,
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger,
      settings: storage.settings
    )
    backendProxy.initialize()

    let authenticatedApiType = try await backendProxy.login(
      apiType: .notDetected,
      credentials: credentials
    )

    credentials.backendApi = authenticatedApiType
    backendProxy.selectedApi = authenticatedApiType

    let account = library.getAccount(info: accountInfo)
    let updatedAccountInfo = Account.createInfo(credentials: credentials)
    account.assignInfo(info: updatedAccountInfo)
    storage.main.saveContext()

    storage.settings.accounts.login(credentials)
    backendProxy.provideCredentials(credentials: credentials)

    _backendProxy = backendProxy
    _account = account
    _librarySyncer = LibrarySyncerProxy(
      backendApi: backendProxy,
      account: account,
      storage: storage
    )

    return authenticatedApiType
  }

  /// Runs the initial library sync. Must be called after a successful `login()`.
  @MainActor
  public func syncInitial(statusNotifyier: SyncCallbacks?) async throws {
    guard let librarySyncer = _librarySyncer else {
      fatalError("syncInitial() called before login()")
    }
    try await librarySyncer.syncInitial(statusNotifyier: statusNotifyier)

    if let account = _account {
      storage.settings.accounts.updateSetting(account.info) { accountSettings in
        accountSettings.initialSyncCompletionStatus = .completed
      }
    }
    storage.settings.app.isLibrarySynced = true
  }

  /// Syncs a single album's songs from the server. Must be called after `syncInitial()`.
  @MainActor
  public func sync(album: Album) async throws {
    guard let librarySyncer = _librarySyncer else {
      fatalError("sync(album:) called before login()")
    }
    try await librarySyncer.sync(album: album)
  }

  /// Syncs a single playlist's songs from the server. Must be called after `syncInitial()`.
  @MainActor
  public func syncDown(playlist: Playlist) async throws {
    guard let librarySyncer = _librarySyncer else {
      fatalError("syncDown(playlist:) called before login()")
    }
    try await librarySyncer.syncDown(playlist: playlist)
  }

  /// Searches the server for songs matching the given text and stores results in CoreData.
  /// After this call returns, `library.searchSongs()` will find the server-synced results.
  @MainActor
  public func searchSongs(searchText: String) async throws {
    guard let librarySyncer = _librarySyncer else {
      fatalError("searchSongs(searchText:) called before login()")
    }
    try await librarySyncer.searchSongs(searchText: searchText)
  }

  /// Whether the initial sync has been completed for the active account.
  public var isSyncCompleted: Bool {
    let accountSetting = storage.settings.accounts.activeSetting.read
    let syncStatus = accountSetting.initialSyncCompletionStatus
    return syncStatus == .completed || syncStatus == .skipped
  }
}

// MARK: - AlwaysConnectedNetworkMonitor

/// Minimal network monitor that always reports connectivity.
/// Used by StandaloneAmperfyKit since GX runs on Mac (always online)
/// and the real NetworkMonitor has iOS-specific dependencies.
private final class AlwaysConnectedNetworkMonitor: NetworkMonitorFacade, @unchecked Sendable {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack?
  var isConnectedToNetwork: Bool { true }
  var isCellular: Bool { false }
  var isWifiOrEthernet: Bool { true }
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
