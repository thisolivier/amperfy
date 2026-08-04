//
//  PlaylistFolderBrowsingTableViewController.swift
//  Amperfy
//
//  Created by the Amperfy spike (Feature G — Playlist folders).
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

import AmperfyKit
import CoreData
import UIKit

// MARK: - PlaylistFolderBrowsingTableViewController

/// Shared base for the folder-aware playlist browsing tables. Both the main
/// Playlists screen (`PlaylistFolderContentsVC`) and the "Add to Playlist"
/// picker (`PlaylistSelectorVC`) present the same two-section list — top-level
/// folders plus (unfiled) playlists at the root, or a folder's subfolders plus
/// its playlists when folder-scoped — with always-on search and sort.
///
/// This base owns the data loading, the section/cell plumbing, the search
/// controller, and the folder-change observer. Subclasses override the small
/// set of hooks below to supply their screen-specific behavior (what a folder
/// tap pushes, what a playlist tap does, edit-mode interception, and the two
/// playlist-cell styling differences).
class PlaylistFolderBrowsingTableViewController: UITableViewController {
  // MARK: - Sections

  enum Section: Int, CaseIterable {
    case folders = 0
    case playlists = 1
  }

  // MARK: - Properties

  let account: Account
  let parentFolderId: UUID?
  let folderStore = PlaylistFolderStore.shared

  var displayedFolders: [PlaylistFolder] = []
  var displayedPlaylists: [Playlist] = []
  private var folderObserver: (any NSObjectProtocol)?

  var sortType: PlaylistSortType = .name
  var searchText: String = ""

  /// Whether rows follow the folder tree's own ordering — the sibling
  /// comparator over `sortOrder` — rather than one of the attribute sorts.
  ///
  /// This is the default, because it is the order the user arranged. Picking any
  /// attribute sort turns it off for the duration of that choice.
  var usesManualSiblingOrder = true

  // MARK: - Search

  lazy var searchController: UISearchController = {
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

  init(account: Account, parentFolderId: UUID?) {
    self.account = account
    self.parentFolderId = parentFolderId
    super.init(style: .grouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  /// Wires up the folder-change observer. Call from the subclass `viewDidLoad`
  /// after it has configured its own nav items / toolbar.
  func startObservingFolderChanges() {
    folderObserver = NotificationCenter.default.addObserver(
      forName: PlaylistFolderStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reloadContent()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent, let folderObserver {
      NotificationCenter.default.removeObserver(folderObserver)
      self.folderObserver = nil
    }
  }

  // MARK: - Data loading

  func reloadContent() {
    if let parentFolderId {
      guard let folder = folderStore.folder(byId: parentFolderId) else {
        // The folder we were viewing has been deleted (e.g. via the
        // flatten-on-delete path from elsewhere). Pop back to the parent view
        // rather than silently rendering an empty list.
        navigationController?.popViewController(animated: true)
        return
      }
      displayedFolders = sortFolders(folder.subfolders)
      displayedPlaylists = fetchPlaylists(ids: folder.playlistIds)
    } else {
      // During an active root search the playlist list is exhaustive (it
      // surfaces playlists nested in folders too), so hide the folder section
      // to keep results flat and unambiguous.
      displayedFolders = searchText.isEmpty ? sortFolders(folderStore.folders) : []
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

    // At the root, an active search surfaces every playlist — including those
    // nested inside folders at any depth — so a search from the top level is
    // exhaustive. With no search text we show only unfiled playlists (folders
    // carry the rest). Folder-scoped views never reach this method.
    var playlists: [Playlist]
    if searchText.isEmpty {
      playlists = allPlaylists.filter { !$0.isSmartPlaylist && !filedIds.contains($0.id) }
    } else {
      playlists = allPlaylists.filter { !$0.isSmartPlaylist }
    }

    if isOffline {
      playlists = playlists.filter { $0.playables.contains { $0.isCached } }
    }

    if !searchText.isEmpty {
      playlists = playlists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
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
      playlists = playlists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }

    return sortPlaylists(playlists)
  }

  /// Order playlists by the sibling comparator: `sortOrder` ascending, ties
  /// broken by name, and playlists with no placement in this parent last.
  ///
  /// Folders and playlists share one ordering space per parent, but the table
  /// renders them as two sections, so what each section shows is that single
  /// order projected onto its own members. The relative order within each
  /// section is identical to the interleaved order.
  private func sortPlaylistsBySiblingOrder(_ playlists: [Playlist]) -> [Playlist] {
    let sortOrdersByPlaylistId = folderStore.playlistSortOrders(inFolder: parentFolderId)
    return playlists
      .map { playlist in
        (
          playlist: playlist,
          sibling: PlaylistFolderSibling(
            kind: .playlist,
            id: playlist.id,
            name: playlist.name,
            sortOrder: sortOrdersByPlaylistId[playlist.id]
          )
        )
      }
      .sorted { PlaylistFolderOrdering.isOrderedBefore($0.sibling, $1.sibling) }
      .map(\.playlist)
  }

  /// Folders as delivered by the store are already in sibling order. The
  /// attribute sorts have no meaning for folders, so they fall back to name.
  private func sortFolders(_ folders: [PlaylistFolder]) -> [PlaylistFolder] {
    guard !usesManualSiblingOrder else { return folders }
    return folders
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func sortPlaylists(_ playlists: [Playlist]) -> [Playlist] {
    guard !usesManualSiblingOrder else {
      return sortPlaylistsBySiblingOrder(playlists)
    }
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

  // MARK: - Sort menu

  /// Builds a sort menu; each subclass wires the returned menu into its own
  /// nav item or toolbar. Selecting an option updates `sortType`, asks the
  /// subclass to rebuild its nav items, and reloads.
  func createSortButtonMenu() -> UIMenu {
    let manualOrderAction = UIAction(
      title: "Manual",
      image: usesManualSiblingOrder ? .check : nil
    ) { [weak self] _ in
      guard let self else { return }
      usesManualSiblingOrder = true
      rebuildNavigationItemsForSortChange()
      reloadContent()
    }

    let sortOptions: [(String, PlaylistSortType)] = [
      ("Name", .name),
      ("Last time played", .lastPlayed),
      ("Change date", .lastChanged),
      ("Duration", .duration),
    ]
    let attributeSortActions = sortOptions.map { title, option in
      UIAction(
        title: title,
        image: (!usesManualSiblingOrder && sortType == option) ? .check : nil
      ) { [weak self] _ in
        guard let self else { return }
        usesManualSiblingOrder = false
        sortType = option
        rebuildNavigationItemsForSortChange()
        reloadContent()
      }
    }
    return UIMenu(
      title: "Sort",
      image: .sort,
      options: [],
      children: [manualOrderAction] + attributeSortActions
    )
  }

  // MARK: - Overridable hooks

  /// Returns the correct subclass instance to push when a folder row is tapped.
  func makeChildBrowser(parentFolderId: UUID) -> UITableViewController {
    fatalError("Subclasses must override makeChildBrowser(parentFolderId:)")
  }

  /// Called when a playlist row is tapped (and selection was not intercepted).
  func onPlaylistSelected(_ playlist: Playlist, at indexPath: IndexPath) {
    fatalError("Subclasses must override onPlaylistSelected(_:at:)")
  }

  /// Return `true` to prevent the base selection handling from running, letting
  /// the subclass handle the tap itself (e.g. multi-select in edit mode).
  func shouldInterceptSelection(at indexPath: IndexPath) -> Bool { false }

  /// Whether playlist cells show the leading cache-status fragment in the
  /// detail line. The main screen wants this; the picker does not.
  var playlistCellShowsCacheStatus: Bool { true }

  /// Accessory shown on playlist cells. The main screen navigates (disclosure);
  /// the picker adds on tap (none).
  var playlistCellAccessoryType: UITableViewCell.AccessoryType { .disclosureIndicator }

  /// Called after a sort option is chosen so the subclass can refresh whatever
  /// UI carries the sort menu (the checkmark on the selected option). Default
  /// is a no-op; subclasses override to rebuild their nav items.
  func rebuildNavigationItemsForSortChange() {}

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
    if playlistCellShowsCacheStatus, let cachePrefix = cacheStatusPrefix(for: playlist) {
      cell.detailTextLabel?.text = "\(cachePrefix) · \(infoText)"
    } else {
      cell.detailTextLabel?.text = infoText
    }
    cell.detailTextLabel?.textColor = ThemeStore.shared.dynamicText?.withAlphaComponent(0.6)
      ?? .secondaryLabel
    cell.accessoryType = playlistCellAccessoryType
    cell.tintColor = ThemeStore.shared.dynamicTint ?? .systemBlue
    cell.backgroundColor = ThemeStore.shared.dynamicBackground ?? .secondarySystemGroupedBackground
    return cell
  }

  private func cacheStatusPrefix(for playlist: Playlist) -> String? {
    let playables = playlist.playables
    let cachedCount = playables.filterCached().count
    let totalCount = playables.count
    let isOffline = appDelegate.storage.settings.user.isOfflineMode
    if cachedCount == totalCount, totalCount > 0 {
      return "Cached"
    } else if isOffline, cachedCount > 0 {
      return "\(cachedCount) cached"
    } else {
      return nil
    }
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if shouldInterceptSelection(at: indexPath) { return }
    switch Section(rawValue: indexPath.section) {
    case .folders:
      let folder = displayedFolders[indexPath.row]
      let childVC = makeChildBrowser(parentFolderId: folder.id)
      navigationController?.pushViewController(childVC, animated: true)
    case .playlists:
      let playlist = displayedPlaylists[indexPath.row]
      onPlaylistSelected(playlist, at: indexPath)
    case .none:
      break
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }
}

// MARK: UISearchResultsUpdating

extension PlaylistFolderBrowsingTableViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    reloadContent()
  }
}
