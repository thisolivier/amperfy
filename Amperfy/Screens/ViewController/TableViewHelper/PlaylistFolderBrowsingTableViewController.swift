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
/// picker (`PlaylistSelectorVC`) present the same single interleaved list —
/// top-level folders and unfiled playlists at the root, or a folder's subfolders
/// and its playlists when folder-scoped — with always-on search and sort.
///
/// Folders and playlists are one list, not two sections, because they are one
/// ordering space: a playlist deliberately placed between two folders has to
/// render between them. `displayedRows` is that merged list.
///
/// This base owns the data loading, the row/cell plumbing, the search
/// controller, and the folder-change observer. Subclasses override the small
/// set of hooks below to supply their screen-specific behavior (what a folder
/// tap pushes, what a playlist tap does, edit-mode interception, and the two
/// playlist-cell styling differences).
class PlaylistFolderBrowsingTableViewController: UITableViewController {
  // MARK: - Rows

  /// One entry in the single interleaved list. Folders and playlists share one
  /// ordering space per parent, so they share one section too — see
  /// `PlaylistFolderBrowseListBuilder` for why the two-section layout was wrong.
  enum PlaylistFolderBrowseRow {
    case folder(PlaylistFolder)
    case playlist(Playlist)

    var identity: PlaylistFolderBrowseRowIdentity {
      switch self {
      // The server's folder id verbatim — opaque and case sensitive, never
      // parsed into anything.
      case let .folder(folder): return .folder(folder.id)
      case let .playlist(playlist): return .playlist(playlist.id)
      }
    }

    var displayName: String {
      switch self {
      case let .folder(folder): return folder.name
      case let .playlist(playlist): return playlist.name
      }
    }

    var asFolder: PlaylistFolder? {
      guard case let .folder(folder) = self else { return nil }
      return folder
    }

    var asPlaylist: Playlist? {
      guard case let .playlist(playlist) = self else { return nil }
      return playlist
    }
  }

  // MARK: - Properties

  let account: Account
  let parentFolderId: String?
  let folderStore = PlaylistFolderStore.shared

  var displayedFolders: [PlaylistFolder] = []
  var displayedPlaylists: [Playlist] = []
  /// The rendered list: subfolders and playlists interleaved in sibling order.
  var displayedRows: [PlaylistFolderBrowseRow] = []
  private var folderObserver: (any NSObjectProtocol)?

  var displayedRowIdentities: [PlaylistFolderBrowseRowIdentity] {
    displayedRows.map(\.identity)
  }

  func row(at rowIndex: Int) -> PlaylistFolderBrowseRow? {
    displayedRows.indices.contains(rowIndex) ? displayedRows[rowIndex] : nil
  }

  func row(at indexPath: IndexPath) -> PlaylistFolderBrowseRow? {
    row(at: indexPath.row)
  }

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

  init(account: Account, parentFolderId: String?) {
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
    displayedRows = buildInterleavedRows()
    tableView.reloadData()
    updateContentUnavailable()
    didReloadRows()
  }

  /// Merge the fetched folders and playlists into the one list the table shows.
  ///
  /// Both inputs are already filtered by search and offline mode, so whatever
  /// survives is ordered here with the shared sibling comparator. Under an
  /// attribute sort the two are concatenated instead — sorting a folder by
  /// duration means nothing — but it is still one list, not two sections.
  private func buildInterleavedRows() -> [PlaylistFolderBrowseRow] {
    let folderSiblings = displayedFolders.map {
      PlaylistFolderSibling(
        kind: .folder,
        id: $0.id,
        name: $0.name,
        sortOrder: $0.sortOrder
      )
    }
    let playlistSortOrders = folderStore.playlistSortOrders(inFolder: parentFolderId)
    let playlistSiblings = displayedPlaylists.map {
      PlaylistFolderSibling(
        kind: .playlist,
        id: $0.id,
        name: $0.name,
        sortOrder: playlistSortOrders[$0.id]
      )
    }

    let foldersById = Dictionary(
      displayedFolders.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let playlistsById = Dictionary(
      displayedPlaylists.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    return PlaylistFolderBrowseListBuilder.rowIdentities(
      folderSiblings: folderSiblings,
      playlistSiblings: playlistSiblings,
      keepsFoldersFirst: !usesManualSiblingOrder
    ).compactMap { identity in
      switch identity.kind {
      case .folder:
        return foldersById[identity.id].map { PlaylistFolderBrowseRow.folder($0) }
      case .playlist:
        return playlistsById[identity.id].map { PlaylistFolderBrowseRow.playlist($0) }
      }
    }
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
  /// This orders the playlists among themselves; `buildInterleavedRows()` then
  /// merges them with the folders into the single order actually rendered.
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
    if displayedRows.isEmpty {
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
  func makeChildBrowser(parentFolderId: String) -> UITableViewController {
    fatalError("Subclasses must override makeChildBrowser(parentFolderId:)")
  }

  /// Called when a playlist row is tapped (and selection was not intercepted).
  func onPlaylistSelected(_ playlist: Playlist, at indexPath: IndexPath) {
    fatalError("Subclasses must override onPlaylistSelected(_:at:)")
  }

  /// Return `true` to prevent the base selection handling from running, letting
  /// the subclass handle the tap itself (e.g. multi-select in edit mode).
  func shouldInterceptSelection(at indexPath: IndexPath) -> Bool { false }

  /// Called at the end of every `reloadContent()`, after `displayedRows` and the
  /// table have been refreshed. Subclasses holding row-index state — a
  /// selection, a keyboard focus — reconcile it here.
  func didReloadRows() {}

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

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    displayedRows.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch row(at: indexPath) {
    case let .folder(folder):
      return folderCell(for: folder)
    case let .playlist(playlist):
      return playlistCell(for: playlist)
    case .none:
      return UITableViewCell()
    }
  }

  private func folderCell(for folder: PlaylistFolder) -> UITableViewCell {
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

  private func playlistCell(for playlist: Playlist) -> UITableViewCell {
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
    switch row(at: indexPath) {
    case let .folder(folder):
      openFolder(folder)
    case let .playlist(playlist):
      onPlaylistSelected(playlist, at: indexPath)
    case .none:
      break
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }

  /// Push the folder-scoped browser for `folder`. Shared by taps, keyboard
  /// activation and the spring-loaded descend during a drag.
  func openFolder(_ folder: PlaylistFolder) {
    let childVC = makeChildBrowser(parentFolderId: folder.id)
    navigationController?.pushViewController(childVC, animated: true)
  }
}

// MARK: UISearchResultsUpdating

extension PlaylistFolderBrowsingTableViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    reloadContent()
  }
}
