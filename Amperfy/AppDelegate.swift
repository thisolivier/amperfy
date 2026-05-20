//
//  AppDelegate.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 06.06.22.
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

import AmperfyKit
import BackgroundTasks
import Intents
import MediaPlayer
import os.log
@preconcurrency import UIKit

let windowSettingsTitle = "Settings"
let windowMiniPlayerTitle = "MiniPlayer"

let settingsWindowActivityType = "amperfy.settings"
let miniPlayerWindowActivityType = "amperfy.miniplayer"
let defaultWindowActivityType = "amperfy.main"

// MARK: - AppDelegate

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  static let name = "Amperfy"
  static var version: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
  }

  static var buildNumber: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
  }

  /// Task IDs need to be added to the array in Info.list under: <key>BGTaskSchedulerPermittedIdentifiers</key>
  static let refreshTaskId = "de.familie-zimba.Amperfy.RefreshTask"

  static let maxPlayablesDownloadsToAddAtOnceWithoutWarning = 200

  var window: UIWindow?
  var focusedWindowTitle: String?

  lazy var player: PlayerFacade = {
    UIApplication.shared.beginReceivingRemoteControlEvents()
    return AmperKit.shared.player
  }()

  public lazy var log = {
    AmperKit.shared.log
  }()

  public lazy var storage = {
    AmperKit.shared.storage
  }()

  public var networkMonitor: NetworkMonitorFacade { AmperKit.shared.networkMonitor }

  public lazy var eventLogger: EventLogger = {
    AmperKit.shared.eventLogger
  }()

  public lazy var notificationHandler: EventNotificationHandler = {
    AmperKit.shared.notificationHandler
  }()

  public var libraryUpdater: LibraryUpdater { AmperKit.shared.libraryUpdater }

  public lazy var userStatistics = {
    AmperKit.shared.userStatistics
  }()

  public lazy var localNotificationManager = {
    AmperKit.shared.localNotificationManager
  }()

  public func getMeta(_ accountInfo: AccountInfo) -> MetaManager {
    AmperKit.shared.getMeta(accountInfo)
  }

  public func resetMeta(_ accountInfo: AccountInfo) {
    AmperKit.shared.resetMeta(accountInfo)
  }

  public lazy var intentManager = {
    IntentManager(
      storage: storage,
      getLibrarySyncerCB: { accountInfo in
        self.getMeta(accountInfo).librarySyncer
      },
      getPlayableDownloadManagerCB: { accountInfo in
        self.getMeta(accountInfo).playableDownloadManager
      },
      library: storage.main.library,
      getActiveAccountCallback: {
        guard let activeAccountInfo = self.storage.settings.accounts.active else { return nil }
        return self.storage.main.library.getAccount(info: activeAccountInfo)
      },
      player: player, networkMonitor: networkMonitor,
      eventLogger: eventLogger
    )
  }()

  public lazy var quickActionsManager = {
    QuickActionsHandler(
      storage: self.storage,
      player: self.player,
      application: UIApplication.shared,
      displaySearchTabCB: self.displaySearchTab
    )
  }()

  var settingsSceneSession: UISceneSession?
  var miniPlayerSceneSession: UISceneSession?

  var sleepTimer: Timer?

  var isKeepScreenAlive: Bool {
    get { UIApplication.shared.isIdleTimerDisabled }
    set { UIApplication.shared.isIdleTimerDisabled = newValue }
  }

  func configureDefaultNavigationBarStyle() {
    UINavigationBar.appearance().shadowImage = UIImage()
    applyCustomThemeAppearance()
  }

  func applyCustomThemeAppearance() {
    let theme = ThemeStore.shared
    guard theme.isEnabled else {
      // Reset to defaults
      UINavigationBar.appearance().barTintColor = nil
      UINavigationBar.appearance().tintColor = nil
      UINavigationBar.appearance().titleTextAttributes = nil
      UINavigationBar.appearance().largeTitleTextAttributes = nil
      UITabBar.appearance().barTintColor = nil
      UITabBar.appearance().tintColor = nil
      UITabBar.appearance().unselectedItemTintColor = nil
      UITableView.appearance().backgroundColor = nil
      UITableViewCell.appearance().backgroundColor = nil
      UICollectionView.appearance().backgroundColor = nil
      UICollectionViewCell.appearance().backgroundColor = nil
      UISearchBar.appearance().tintColor = nil
      // Reset text color and font proxies
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewCell.self]).textColor = nil
      UILabel.appearance(whenContainedInInstancesOf: [UICollectionViewCell.self]).textColor = nil
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self])
        .textColor = nil
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self])
        .font = nil
      // Reset window-level overrides
      let windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      for window in windowScene.flatMap({ $0.windows }) {
        window.tintColor = nil
      }
      return
    }
    // BUG-1 fix (Release 1 QA): previously `populateDefaultsIfNeeded` was
    // only invoked on the enabled-toggle OFF→ON transition. Pre-17.4
    // installs with a stored `.light.text` but no `.light.headingText`
    // rendered correctly at runtime (via the heading→body→label fallback
    // in `dynamicHeadingText`) but showed `.label` in the Heading picker
    // until the user toggled the theme off-and-on. Calling the populator
    // here closes that gap — every launch with theme enabled migrates
    // missing defaults before any settings UI is rendered. Idempotent
    // (every mutation is nil-gated). Also seeds the PR 17.2 gradient
    // presets on first launch.
    theme.populateDefaultsIfNeeded()
    // PR 17.5: one-shot auto-capture of the current theme state on the
    // first Release-5 launch. Gated by a UserDefaults flag so it runs
    // exactly once. Must run after populateDefaultsIfNeeded so the theme
    // state is fully initialised before we snapshot it.
    StylingPresetStore.shared.performAutoCaptureIfNeeded()
    if let backgroundColor = theme.dynamicBackground {
      UINavigationBar.appearance().barTintColor = backgroundColor
      UITabBar.appearance().barTintColor = backgroundColor
      UITableView.appearance().backgroundColor = backgroundColor
      UITableViewCell.appearance().backgroundColor = backgroundColor
      UICollectionView.appearance().backgroundColor = backgroundColor
    }
    // PR 17.2: when ANY gradient is enabled (either mode) we must clear
    // the cell background proxy so the gradient is visible through the
    // cells. Otherwise the solid `dynamicBackground` cells sit edge-to-
    // edge on top of the gradient and hide it entirely. Overrides the
    // just-set value above — intentional, in that order because the
    // nav/tab/table bar tints still want the opaque background color.
    if theme.isAnyGradientEnabled {
      UITableViewCell.appearance().backgroundColor = .clear
      UICollectionViewCell.appearance().backgroundColor = .clear
    } else {
      UICollectionViewCell.appearance().backgroundColor = nil
    }
    // PR 17.4: nav bar titles, large titles, and default UIKit section
    // headers render in the heading tier; cell body labels render in the
    // body tier. Each tier is applied independently so one being nil does
    // not suppress the other.
    let bodyTextColor = theme.dynamicText
    let headingTextColor = theme.dynamicHeadingText
    if let headingTextColor {
      var titleAttributes: [NSAttributedString.Key: Any] =
        [.foregroundColor: headingTextColor]
      var largeTitleAttributes: [NSAttributedString.Key: Any] =
        [.foregroundColor: headingTextColor]
      let hasAnyFont = theme.lightFontFamily != nil || theme.darkFontFamily != nil
      if hasAnyFont {
        titleAttributes[.font] = UIFont.themed(style: .headline)
        largeTitleAttributes[.font] = UIFont.themed(style: .largeTitle)
      }
      UINavigationBar.appearance().titleTextAttributes = titleAttributes
      UINavigationBar.appearance().largeTitleTextAttributes = largeTitleAttributes
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self])
        .textColor = headingTextColor
      if hasAnyFont {
        UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self])
          .font = UIFont.themed(style: .headline)
      }
    } else if theme.lightFontFamily != nil || theme.darkFontFamily != nil {
      // Font-only (no custom heading color) — still apply font to nav bar
      // titles and default section headers.
      UINavigationBar.appearance().titleTextAttributes = [
        .font: UIFont.themed(style: .headline),
      ]
      UINavigationBar.appearance().largeTitleTextAttributes = [
        .font: UIFont.themed(style: .largeTitle),
      ]
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self])
        .font = UIFont.themed(style: .headline)
    }
    if let bodyTextColor {
      UITabBar.appearance().unselectedItemTintColor = bodyTextColor.withAlphaComponent(0.5)
      UILabel.appearance(whenContainedInInstancesOf: [UITableViewCell.self])
        .textColor = bodyTextColor
      UILabel.appearance(whenContainedInInstancesOf: [UICollectionViewCell.self])
        .textColor = bodyTextColor
    }
    if let tintColor = theme.dynamicTint {
      UINavigationBar.appearance().tintColor = tintColor
      UITabBar.appearance().tintColor = tintColor
      UISearchBar.appearance().tintColor = tintColor
      // Set window-level tint for broad coverage (NOT UIView.appearance()
      // which interferes with system views and causes crashes)
      let windowScenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
      for window in windowScenes.flatMap({ $0.windows }) {
        window.tintColor = tintColor
      }
    }
  }

  func applyCustomThemeAndReload() {
    applyCustomThemeAppearance()
    applyAppThemeToAlreadyLoadedViews()
  }

  func configureBatteryMonitoring() {
    UIDevice.current.isBatteryMonitoringEnabled =
      (AmperKit.shared.storage.settings.user.screenLockPreventionPreference == .onlyIfCharging)
    configureLockScreenPrevention()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(batteryStateDidChange),
      name: UIDevice.batteryStateDidChangeNotification,
      object: nil
    )
  }

  @objc
  private func batteryStateDidChange(notification: NSNotification) {
    configureLockScreenPrevention()
  }

  func configureLockScreenPrevention() {
    os_log(
      "Device Battery Status: %s",
      log: self.log,
      type: .info,
      UIDevice.current.batteryState.description
    )
    switch AmperKit.shared.storage.settings.user.screenLockPreventionPreference {
    case .always:
      isKeepScreenAlive = true
    case .never:
      isKeepScreenAlive = false
    case .onlyIfCharging:
      isKeepScreenAlive = UIDevice.current.batteryState != .unplugged
    }
    os_log("Lock Screen Prevention: %s", log: self.log, type: .info, isKeepScreenAlive.description)
  }

  func configureBackgroundFetch() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshTaskId,
      using: DispatchQueue.main
    ) { bgTask in
      Task { @MainActor in
        await self.performBackgroundFetchTask(bgTask: bgTask)
      }
    }
  }

  @MainActor
  private func performBackgroundFetchTask(bgTask: BGTask) async {
    os_log("Perform task: %s", log: self.log, type: .info, Self.refreshTaskId)
    var success = true
    for accountInfo in storage.settings.accounts.allAccounts {
      do {
        try await getMeta(accountInfo).backgroundFetchTriggeredSyncer.syncAndNotifyPodcastEpisodes()
      } catch {
        success = false
        eventLogger.error(
          topic: "Background Task",
          statusCode: .connectionError,
          message: error.localizedDescription,
          displayPopup: false
        )
      }
    }
    bgTask.setTaskCompleted(success: success)
    userStatistics.backgroundFetchPerformed(result: UIBackgroundFetchResult.newData)
    scheduleAppRefresh()
  }

  func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60) // Refresh after 45 minutes.
    do {
      // Submit only succeeds on real devices. On simulator it will always throw an error.
      try BGTaskScheduler.shared.submit(request)
    } catch {
      os_log(
        "Could not schedule app refresh task (%s) with error: %s",
        log: self.log,
        type: .error,
        Self.refreshTaskId,
        error.localizedDescription
      )
    }
  }

  func initEventLogger() {
    AmperKit.shared.eventLogger.alertDisplayer = self
  }

  func stopForInit() {
    sleepTimer?.invalidate()
    sleepTimer = nil
    player.stop()
  }

  // deprecated
  func restartByUser() {
    Task {
      await localNotificationManager.notifyDebugAndWait(
        title: "Amperfy Restart",
        body: "Tap to reopen Amperfy"
      )
      stopForInit()
      // close Amperfy
      exit(0)
    }
  }

  var isNormalInteraction: Bool {
    storage.settings.accounts.active != nil && !libraryUpdater
      .isVisualUpadateNeeded
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  )
    -> Bool {
    if let options = launchOptions {
      os_log("application launch with options:", log: self.log, type: .info)
      options
        .forEach { os_log("- key: %s", log: self.log, type: .info, $0.key.rawValue.description) }
    } else {
      os_log("application launch", log: self.log, type: .info)
    }

    MemoryReporter.clearLog()
    MemoryReporter.logMemory(label: "app-launch-start")

    // PR 19a: sweep any .running statuses left over from a prior terminated session.
    BackgroundTaskRunner.shared.performLaunchSweep()

    storage.applyMultiAccountSettingsUpdateIfNeeded()
    libraryUpdater.performAccountCleanUpIfNeccessaryInBackground()

    configureDefaultNavigationBarStyle()
    configureBatteryMonitoring()
    configureBackgroundFetch()
    configureNotificationHandling()
    initEventLogger()

    guard let activeAccountInfo = appDelegate.storage.settings.accounts.active else {
      return true
    }

    setAppTheme(
      color: storage.settings.accounts.getSetting(activeAccountInfo).read.themePreference
        .asColor
    )

    guard AmperKit.shared.storage.settings.app.isLibrarySynced else {
      return true
    }

    os_log(
      "Amperfy Cache Location: %s",
      log: self.log,
      type: .info,
      CacheFileManager.shared.getAmperfyPath() ?? "-"
    )
    MemoryReporter.logMemory(label: "before-blocking-updates")
    libraryUpdater.performSmallBlockingLibraryUpdatesIfNeeded()
    MemoryReporter.logMemory(label: "after-blocking-updates")
    // start manager only if no visual indicated updates are needed
    if !libraryUpdater.isVisualUpadateNeeded {
      startManagerForNormalOperation()
    }
    MemoryReporter.logMemory(label: "after-start-manager")
    userStatistics.sessionStarted()
    // Configure adjacency service with Core Data context provider
    let adjacencyStorage = storage
    DefaultTrackAdjacencyService.configure(contextProvider: {
      adjacencyStorage.newBackgroundContext()
    })
    // Configure playlist folder sync for Navidrome accounts
    if let loginCredentials = storage.settings.accounts.getSetting(activeAccountInfo).read.loginCredentials {
      let folderApi: NavidromeServerApi? = (loginCredentials.backendApi == .subsonic)
        ? NavidromeServerApi(credentials: loginCredentials) : nil
      let accountMO = storage.main.library.getAccount(info: activeAccountInfo).managedObject
      PlaylistFolderStore.shared.configure(
        context: storage.main.context,
        navidromeApi: folderApi,
        account: accountMO
      )
    }

    if storage.settings.app.isLibrarySynced {
      // Adjacency runs through the unified runner (AdjacencyWorker).
      // Worker registration happens in MetaManager.registerRunnerWorkers() which is
      // called from startManagerForNormalOperation above. Enqueue after that.
      BackgroundTaskRunner.shared.enqueue(
        TaskDescriptor(kind: .adjacencyCompute, triggerReason: .scheduled)
      )
    }

    // Mark playlist item sync as disabled if Phase 2 is off.
    if !BackgroundRunnerFeatureFlags.shared.phase2Enabled {
      BackgroundTaskStatusStore.shared.transition(
        .playlistItemSync,
        to: .disabled(reason: "Phase 2 disabled")
      )
    }

    return true
  }

  private var isAlreadyRegisteredToPlayer = false
  func startManagerAfterSync() {
    os_log("Start background manager after sync", log: self.log, type: .info)
    configureMainMenu()
    intentManager.registerXCallbackURLs()
    if !isAlreadyRegisteredToPlayer {
      isAlreadyRegisteredToPlayer = true
      player.addNotifier(notifier: self)
    }
    // Adjacency recomputation is now handled by BackgroundLibrarySyncer
    // after playlist items are synced — no need to eagerly recompute here.
  }

  func startManagerForNormalOperation() {
    os_log("Start background manager for normal operation", log: self.log, type: .info)
    configureMainMenu()
    intentManager.registerXCallbackURLs()
    for accountInfo in storage.settings.accounts.allAccounts {
      getMeta(accountInfo).startManagerForNormalOperation(player: appDelegate.player)
    }
    isAlreadyRegisteredToPlayer = true
    player.addNotifier(notifier: self)
  }

  func setAppTheme(color: UIColor) {
    // Custom theme tint takes priority over account theme color
    let effectiveColor = ThemeStore.shared.dynamicTint ?? color
    // Apply to targeted appearance proxies, not UIView.appearance()
    UINavigationBar.appearance().tintColor = effectiveColor
    UITabBar.appearance().tintColor = effectiveColor
    UISearchBar.appearance().tintColor = effectiveColor
  }

  // the following applies the tint color to already loaded views in all windows (UIKit)
  func applyAppThemeToAlreadyLoadedViews() {
    let windowScenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let windows = windowScenes.flatMap { $0.windows }

    let tintColor = ThemeStore.shared.dynamicTint
    for window in windows {
      if let tintColor {
        window.tintColor = tintColor
      }
      // Safe re-layout — no remove/re-add which can crash when
      // concurrent background work (e.g. adjacency engine) is running
      window.setNeedsLayout()
      window.layoutIfNeeded()
    }
  }

  func switchAccount(accountInfo: AccountInfo) {
    storage.settings.accounts.switchActiveAccount(accountInfo)
    notificationHandler.post(
      name: .accountActiveChanged,
      object: nil,
      userInfo: nil
    )
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    // Reconfigure playlist folder store for new account
    if let loginCredentials = appDelegate.storage.settings.accounts.getSetting(accountInfo).read.loginCredentials {
      let folderApi: NavidromeServerApi? = (loginCredentials.backendApi == .subsonic)
        ? NavidromeServerApi(credentials: loginCredentials) : nil
      PlaylistFolderStore.shared.configure(
        context: appDelegate.storage.main.context,
        navidromeApi: folderApi,
        account: account.managedObject
      )
    }

    closeAllButActiveMainTabs()
    setAppTheme(
      color: appDelegate.storage.settings.accounts.getSetting(accountInfo)
        .read.themePreference.asColor
    )
    applyAppThemeToAlreadyLoadedViews()
    AmperfyAppShortcuts.updateAppShortcutParameters()
    guard let mainScene = AppDelegate.mainSceneDelegate else { return }
    mainScene
      .replaceMainRootViewController(
        vc: AppStoryboard.Main
          .segueToMainWindow(account: account)
      )
  }

  func switchOnlineOfflineMode(isOfflineMode: Bool) {
    appDelegate.storage.settings.user.isOfflineMode = isOfflineMode
    appDelegate.notificationHandler.post(
      name: .offlineModeChanged,
      object: nil,
      userInfo: nil
    )
  }

  func setAppAppearanceMode(style: UIUserInterfaceStyle) {
    if #available(iOS 13.0, *) {
      UIApplication.shared.connectedScenes
        .forEach {
          if let windowScene = $0 as? UIWindowScene {
            windowScene.windows.forEach { window in
              window.overrideUserInterfaceStyle = style
              window.rootViewController?.overrideUserInterfaceStyle = style
            }
          }
        }
    }
  }

  func applicationWillResignActive(_ application: UIApplication) {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    os_log("applicationWillResignActive", log: self.log, type: .info)
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    os_log("applicationDidEnterBackground", log: self.log, type: .info)
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    os_log("applicationWillEnterForeground", log: self.log, type: .info)
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    os_log("applicationDidBecomeActive", log: self.log, type: .info)
  }

  func applicationWillTerminate(_ application: UIApplication) {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    os_log("applicationWillTerminate", log: self.log, type: .info)
    for meta in AmperKit.shared.allActiveMetas {
      meta.value.backgroundLibrarySyncer.stop()
    }
    storage.main.saveContext()
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @Sendable @escaping () -> ()
  ) {
    os_log("handleEventsForBackgroundURLSession: %s", log: self.log, type: .info, identifier)
    let responsibleMeta = AmperKit.shared.allActiveMetas
      .first(where: { $0.value.playableDownloadManager.urlSessionIdentifier == identifier })
    responsibleMeta?.value.playableDownloadManager
      .setBackgroundFetchCompletionHandler(completionHandler)
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  )
    -> UISceneConfiguration {
    guard connectingSceneSession.role != .carTemplateApplication else {
      let config = UISceneConfiguration(
        name: "CarPlay Configuration",
        sessionRole: .carTemplateApplication
      )
      config.delegateClass = CarPlaySceneDelegate.self
      return config
    }

    if options.userActivities.filter({ $0.activityType == settingsWindowActivityType })
      .first != nil {
      let config = UISceneConfiguration(name: "Settings", sessionRole: .windowApplication)
      config.delegateClass = SettingsSceneDelegate.self
      return config
    }

    if options.userActivities.filter({ $0.activityType == miniPlayerWindowActivityType })
      .first != nil {
      let config = UISceneConfiguration(name: "MiniPlayer", sessionRole: .windowApplication)
      config.delegateClass = MiniPlayerSceneDelegate.self
      return config
    }

    let config = UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: .windowApplication
    )
    config.delegateClass = SceneDelegate.self
    return config
  }

  func application(
    _ application: UIApplication,
    didDiscardSceneSessions sceneSessions: Set<UISceneSession>
  ) {
    os_log("didDiscardSceneSessions", log: self.log, type: .info)
  }

  func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    os_log("application handlerFor intent", log: self.log, type: .info)
    // This is the default implementation.  If you want different objects to handle different intents,
    // you can override this and return the handler you want for that particular intent.
    if intent is INPlayMediaIntent {
      return PlayMediaIntentHandler(intentManager: intentManager)
    }
    return nil
  }
}
