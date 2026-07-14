//
//  PlaylistSelectorVC.swift
//  Amperfy
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

import AmperfyKit
import CoreData
import UIKit

// MARK: - PlaylistSelectorVC

/// Modal picker used by "Add to Playlist". Mirrors the folder-aware layout of
/// `PlaylistFolderContentsVC`: at the root it shows top-level folders plus
/// unfiled playlists; tapping a folder pushes a folder-scoped picker instance;
/// tapping a playlist adds the pending song(s) to it immediately (without
/// dismissing). A bottom-corner "+" creates a new playlist. The modal only
/// closes when the user taps the close button, so several playlists can be
/// filled in one session.
class PlaylistSelectorVC: UITableViewController {
  // MARK: - Sections

  private enum Section: Int, CaseIterable {
    case folders = 0
    case playlists = 1
  }

  // MARK: - Properties

  private let account: Account
  let itemsToAdd: [Song]
  private let parentFolderId: UUID?
  private let folderStore = PlaylistFolderStore.shared

  private var displayedFolders: [PlaylistFolder] = []
  private var displayedPlaylists: [Playlist] = []
  private var folderObserver: (any NSObjectProtocol)?

  private var sortType: PlaylistSortType = .name
  private var searchText: String = ""

  private var closeButton: UIBarButtonItem!
  private var optionsButton: UIBarButtonItem!
  private var addBarButton: UIBarButtonItem!

  // MARK: - Search

  private lazy var searchController: UISearchController = {
    let controller = UISearchController(searchResultsController: nil)
    controller.searchResultsUpdater = self
    controller.obscuresBackgroundDuringPresentation = false
    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
      controller.searchBar.placeholder = "Search in \"\(folder.name)\""
    } else {
      controller.searchBar.placeholder = "Search in \"Playlists\""
    }
    return controller
  }()

  // MARK: - Init

  init(account: Account, itemsToAdd: [Song], parentFolderId: UUID? = nil) {
    self.account = account
    self.itemsToAdd = itemsToAdd
    self.parentFolderId = parentFolderId
    super.init(style: .grouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    appDelegate.userStatistics.visited(.playlistSelector)
    sortType = appDelegate.storage.settings.user.playlistsSortSetting

    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
      title = folder.name
    } else {
      title = itemsToAdd.count > 1
        ? "Add \(itemsToAdd.count) Songs to Playlist"
        : "Add to Playlist"
    }

    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = UITableView.automaticDimension
    tableView.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemGroupedBackground

    navigationItem.searchController = searchController
    definesPresentationContext = true

    updateNavigationItems()
    configureToolbar()

    folderObserver = NotificationCenter.default.addObserver(
      forName: PlaylistFolderStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reloadContent()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadContent()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
      self.reloadContent()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent, let folderObserver {
      NotificationCenter.default.removeObserver(folderObserver)
      self.folderObserver = nil
    }
  }

  // MARK: - Navigation items

  private func updateNavigationItems() {
    closeButton = UIBarButtonItem.createCloseBarButton(
      target: self,
      selector: #selector(closeBarButtonPressed)
    )
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = createSortButtonMenu()
    navigationItem.rightBarButtonItems = [closeButton, optionsButton]
  }

  private func configureToolbar() {
    navigationController?.setToolbarHidden(false, animated: false)
    let flexible = UIBarButtonItem(
      barButtonSystemItem: .flexibleSpace,
      target: self,
      action: nil
    )
    addBarButton = UIBarButtonItem(
      image: .plus,
      style: .plain,
      target: self,
      action: #selector(createPlaylistBarButtonPressed)
    )
    toolbarItems = [flexible, addBarButton]
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortOptions: [(String, PlaylistSortType)] = [
      ("Name", .name),
      ("Last time played", .lastPlayed),
      ("Change date", .lastChanged),
      ("Duration", .duration),
    ]
    let actions = sortOptions.map { title, option in
      UIAction(
        title: title,
        image: sortType == option ? .check : nil
      ) { [weak self] _ in
        guard let self else { return }
        sortType = option
        updateNavigationItems()
        reloadContent()
      }
    }
    return UIMenu(title: "Sort", image: .sort, options: [], children: actions)
  }

  // MARK: - Actions

  @objc
  private func closeBarButtonPressed(_ sender: UIBarButtonItem) {
    dismissSelf()
  }

  @objc
  private func createPlaylistBarButtonPressed(_ sender: UIBarButtonItem) {
    promptCreatePlaylist()
  }

  private func dismissSelf() {
    searchController.dismiss(animated: false, completion: nil)
    dismiss(animated: true, completion: nil)
  }

  // MARK: - Create playlist

  private func promptCreatePlaylist() {
    let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.placeholder = "Playlist name"
      textField.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
      guard let self,
            let name = alert.textFields?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { return }
      createPlaylistAndAddPendingSongs(named: name)
    })
    present(alert, animated: true)
  }

  /// Creates a playlist, adds the pending song(s) to it, files it into the
  /// current folder when the picker is folder-scoped, and keeps the modal open.
  private func createPlaylistAndAddPendingSongs(named name: String) {
    let library = appDelegate.storage.main.library
    let playlist = library.createPlaylist(account: account)
    playlist.name = name
    appDelegate.storage.main.saveContext()

    if let parentFolderId {
      folderStore.addPlaylists([playlist.id], to: parentFolderId)
    }

    addPendingSongs(to: playlist, playables: itemsToAdd, showConfirmationAt: nil)

    if appDelegate.storage.settings.user.isOnlineMode {
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncUpload(playlistToUpdateName: playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Create", error: error)
      }}
    }

    reloadContent()
  }

  // MARK: - Adding songs

  /// Uploads the given playables to the playlist and appends them locally.
  /// When `showConfirmationAt` is provided, a transient checkmark is flashed on
  /// that row so the user gets non-blocking feedback that the add succeeded.
  private func addPendingSongs(
    to playlist: Playlist,
    playables: [AbstractPlayable],
    showConfirmationAt indexPath: IndexPath?
  ) {
    let songs = playables.filterSongs()
    guard !songs.isEmpty else { return }

    playlist.append(playables: songs)
    if let indexPath {
      flashAddedConfirmation(at: indexPath)
    }

    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer.syncUpload(
        playlistToAddSongs: playlist,
        songs: songs
      )
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Add Songs", error: error)
    }}
  }

  private func flashAddedConfirmation(at indexPath: IndexPath) {
    guard let cell = tableView.cellForRow(at: indexPath) else { return }
    let checkmark = UIImageView(image: .check)
    checkmark.tintColor = appDelegate.storage.settings.accounts
      .getSetting(account.info).read.themePreference.asColor
    cell.accessoryView = checkmark
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak cell] in
      cell?.accessoryView = nil
    }
  }

  // MARK: - Data loading

  private func reloadContent() {
    if let parentFolderId {
      guard let folder = folderStore.folder(byId: parentFolderId) else {
        navigationController?.popViewController(animated: true)
        return
      }
      displayedFolders = folder.subfolders
      displayedPlaylists = fetchPlaylists(ids: folder.playlistIds)
    } else {
      displayedFolders = folderStore.folders
      displayedPlaylists = fetchUnfiledPlaylists()
    }
    tableView.reloadData()
    updateContentUnavailable()
  }

  private func fetchUnfiledPlaylists() -> [Playlist] {
    let library = appDelegate.storage.main.library
    let allPlaylists = library.getPlaylists(for: account)
    let filedIds = folderStore.allFiledPlaylistIds
    let isOffline = appDelegate.storage.settings.user.isOfflineMode
    var playlists = allPlaylists
      .filter { !$0.isSmartPlaylist && !filedIds.contains($0.id) }

    if isOffline {
      playlists = playlists.filter { $0.playables.contains { $0.isCached } }
    }

    if !searchText.isEmpty {
      playlists = playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    return sortPlaylists(playlists)
  }

  private func fetchPlaylists(ids: [String]) -> [Playlist] {
    guard !ids.isEmpty else { return [] }
    let library = appDelegate.storage.main.library
    let allPlaylists = library.getPlaylists(for: account)
    let isOffline = appDelegate.storage.settings.user.isOfflineMode
    var playlists = allPlaylists.filter { ids.contains($0.id) }

    if isOffline {
      playlists = playlists.filter { $0.playables.contains { $0.isCached } }
    }

    if !searchText.isEmpty {
      playlists = playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    return sortPlaylists(playlists)
  }

  private func sortPlaylists(_ playlists: [Playlist]) -> [Playlist] {
    switch sortType {
    case .name:
      return playlists
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .lastPlayed:
      return playlists
        .sorted { ($0.lastTimePlayed ?? .distantPast) > ($1.lastTimePlayed ?? .distantPast) }
    case .lastChanged:
      return playlists.sorted { ($0.changeDate ?? .distantPast) > ($1.changeDate ?? .distantPast) }
    case .duration:
      return playlists.sorted { $0.duration > $1.duration }
    }
  }

  private func updateContentUnavailable() {
    if displayedFolders.isEmpty, displayedPlaylists.isEmpty {
      if !searchText.isEmpty {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
      } else {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = .playlist
        config.text = parentFolderId == nil ? "No Playlists" : "Empty Folder"
        contentUnavailableConfiguration = config
      }
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - UITableViewDataSource

  override func numberOfSections(in tableView: UITableView) -> Int {
    Section.allCases.count
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section) {
    case .folders: return displayedFolders.count
    case .playlists: return displayedPlaylists.count
    case .none: return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch Section(rawValue: section) {
    case .folders: return displayedFolders.isEmpty ? nil : "Folders"
    case .playlists:
      if displayedPlaylists.isEmpty { return nil }
      return parentFolderId == nil ? "Playlists" : nil
    case .none: return nil
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch Section(rawValue: indexPath.section) {
    case .folders:
      return folderCell(for: indexPath)
    case .playlists:
      return playlistCell(for: indexPath)
    case .none:
      return UITableViewCell()
    }
  }

  private func folderCell(for indexPath: IndexPath) -> UITableViewCell {
    let folder = displayedFolders[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "FolderCell")
    cell.imageView?.image = UIImage(systemName: "folder.fill")?.withRenderingMode(.alwaysTemplate)
    cell.imageView?.tintColor = ThemeStore.shared.dynamicTint ?? .systemBlue
    cell.textLabel?.text = folder.name
    cell.textLabel?.textColor = ThemeStore.shared.dynamicText ?? .label
    let playlistCount = folder.allPlaylistIdsRecursive.count
    let subfolderCount = folder.subfolders.count
    var details = [String]()
    if playlistCount > 0 {
      details.append("\(playlistCount) playlist\(playlistCount == 1 ? "" : "s")")
    }
    if subfolderCount > 0 {
      details.append("\(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s")")
    }
    cell.detailTextLabel?.text = details.isEmpty ? "Empty" : details.joined(separator: ", ")
    cell.detailTextLabel?.textColor = ThemeStore.shared.dynamicText?
      .withAlphaComponent(0.6) ?? .secondaryLabel
    cell.accessoryType = .disclosureIndicator
    cell.tintColor = ThemeStore.shared.dynamicTint ?? .systemBlue
    cell.backgroundColor = ThemeStore.shared.dynamicBackground ?? .secondarySystemGroupedBackground
    return cell
  }

  private func playlistCell(for indexPath: IndexPath) -> UITableViewCell {
    let playlist = displayedPlaylists[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "PlaylistCell")
    cell.textLabel?.text = playlist.name
    cell.textLabel?.textColor = ThemeStore.shared.dynamicText ?? .label
    let infoText = playlist.info(
      for: playlist.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    cell.detailTextLabel?.text = infoText
    cell.detailTextLabel?.textColor = ThemeStore.shared.dynamicText?.withAlphaComponent(0.6)
      ?? .secondaryLabel
    cell.accessoryType = .none
    cell.tintColor = ThemeStore.shared.dynamicTint ?? .systemBlue
    cell.backgroundColor = ThemeStore.shared.dynamicBackground ?? .secondarySystemGroupedBackground
    return cell
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch Section(rawValue: indexPath.section) {
    case .folders:
      let folder = displayedFolders[indexPath.row]
      let folderPickerVC = PlaylistSelectorVC(
        account: account,
        itemsToAdd: itemsToAdd,
        parentFolderId: folder.id
      )
      navigationController?.pushViewController(folderPickerVC, animated: true)
    case .playlists:
      let playlist = displayedPlaylists[indexPath.row]
      addSongsToPlaylist(playlist, at: indexPath)
    case .none:
      break
    }
  }

  /// Single-tap add: adds the pending song(s) to the tapped playlist and shows
  /// an inline confirmation. When some songs are already present the user is
  /// asked how to handle the duplicates. The modal stays open in every case.
  private func addSongsToPlaylist(_ playlist: Playlist, at indexPath: IndexPath) {
    let itemsNotContained = playlist.notContaines(playables: itemsToAdd)
    if itemsNotContained.count != itemsToAdd.count {
      let alert = UIAlertController(
        title: nil,
        message: "Some Songs are already in this Playlist.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Add Duplicates", style: .default) { [weak self] _ in
        self?.addPendingSongs(
          to: playlist,
          playables: self?.itemsToAdd ?? [],
          showConfirmationAt: indexPath
        )
      })
      alert.addAction(UIAlertAction(title: "Skip Duplicates", style: .default) { [weak self] _ in
        self?.addPendingSongs(
          to: playlist,
          playables: Array(itemsNotContained),
          showConfirmationAt: indexPath
        )
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      present(alert, animated: true)
    } else {
      addPendingSongs(to: playlist, playables: itemsToAdd, showConfirmationAt: indexPath)
    }
  }
}

// MARK: UISearchResultsUpdating

extension PlaylistSelectorVC: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    reloadContent()
  }
}
