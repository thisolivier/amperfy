//
//  PlaylistFolderContentsVC.swift
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

// MARK: - PlaylistFolderContentsVC

/// Shows the contents of a playlist folder (subfolders + playlists), or the
/// root-level view (top-level folders + unfiled playlists) when `parentFolderId`
/// is nil. Replaces `PlaylistsVC` as the Playlists tab entry point.
///
/// v2 redesign: single unified list (no flat/folder toggle), always-on search
/// and sort, custom floating action bar for multi-select (above tab bar).
class PlaylistFolderContentsVC: UITableViewController {
  // MARK: - Sections

  private enum Section: Int, CaseIterable {
    case folders = 0
    case playlists = 1
  }

  // MARK: - Properties

  private let account: Account
  private let parentFolderId: UUID?
  private let folderStore = PlaylistFolderStore.shared

  private var displayedFolders: [PlaylistFolder] = []
  private var displayedPlaylists: [Playlist] = []
  private var folderObserver: (any NSObjectProtocol)?

  private var sortType: PlaylistSortType = .name
  private var searchText: String = ""

  // MARK: - Floating action bar

  private let editActionBar = UIView()
  private var editActionBarButtons: [UIButton] = []
  private var editActionBarBottomConstraint: NSLayoutConstraint?

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

  init(account: Account, parentFolderId: UUID? = nil) {
    self.account = account
    self.parentFolderId = parentFolderId
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent, let folderObserver {
      NotificationCenter.default.removeObserver(folderObserver)
      self.folderObserver = nil
    }
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
      title = folder.name
    } else {
      title = "Playlists"
      navigationItem.largeTitleDisplayMode = .always
    }

    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = PlaylistTableCell.rowHeight
    tableView.backgroundColor = .systemGroupedBackground
    tableView.allowsMultipleSelectionDuringEditing = true

    navigationItem.searchController = searchController
    definesPresentationContext = true

    configureEditActionBar()
    rebuildNavigationItems()

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
    if parentFolderId == nil {
      navigationController?.navigationBar.prefersLargeTitles = true
    }
    reloadContent()
  }

  // MARK: - Navigation items

  private func rebuildNavigationItems() {
    let addFolderAction = UIAction(
      title: "New Folder",
      image: UIImage(systemName: "folder.badge.plus")
    ) { [weak self] _ in
      self?.promptCreateFolder()
    }

    let menuChildren: [UIMenuElement] = [addFolderAction, createSortMenu()]

    let optionsButton = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      menu: UIMenu(children: menuChildren)
    )

    navigationItem.rightBarButtonItems = [optionsButton, editButtonItem]
  }

  private func createSortMenu() -> UIMenu {
    let sortOptions: [(String, PlaylistSortType)] = [
      ("Name", .name),
      ("Last time played", .lastPlayed),
      ("Change date", .lastChanged),
      ("Duration", .duration),
    ]
    let actions = sortOptions.map { title, option in
      UIAction(
        title: title,
        image: sortType == option ? UIImage(systemName: "checkmark") : nil
      ) { [weak self] _ in
        self?.sortType = option
        self?.rebuildNavigationItems()
        self?.reloadContent()
      }
    }
    return UIMenu(
      title: "Sort",
      image: UIImage(systemName: "arrow.up.arrow.down"),
      children: actions
    )
  }

  // MARK: - Floating action bar

  private func configureEditActionBar() {
    editActionBar.translatesAutoresizingMaskIntoConstraints = false
    editActionBar.backgroundColor = .systemBackground
    editActionBar.isHidden = true
    view.addSubview(editActionBar)

    let separator = UIView()
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.backgroundColor = .separator
    editActionBar.addSubview(separator)

    NSLayoutConstraint.activate([
      separator.topAnchor.constraint(equalTo: editActionBar.topAnchor),
      separator.leadingAnchor.constraint(equalTo: editActionBar.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: editActionBar.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 0.5),
    ])

    let stackView = UIStackView()
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.distribution = .fillEqually
    stackView.spacing = 12
    editActionBar.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: editActionBar.topAnchor, constant: 8),
      stackView.leadingAnchor.constraint(equalTo: editActionBar.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: editActionBar.trailingAnchor, constant: -16),
      stackView.bottomAnchor.constraint(equalTo: editActionBar.bottomAnchor, constant: -8),
    ])

    if parentFolderId != nil {
      let moveButton = makeActionBarButton(title: "Move to Folder", action: #selector(moveSelectedToFolder))
      let removeButton = makeActionBarButton(title: "Remove from Folder", action: #selector(removeSelectedFromFolder))
      stackView.addArrangedSubview(moveButton)
      stackView.addArrangedSubview(removeButton)
      editActionBarButtons = [moveButton, removeButton]
    } else {
      let addButton = makeActionBarButton(title: "Add to Folder", action: #selector(addSelectedToFolder))
      stackView.addArrangedSubview(addButton)
      editActionBarButtons = [addButton]
    }

    let barHeight: CGFloat = 50

    NSLayoutConstraint.activate([
      editActionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editActionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editActionBar.heightAnchor.constraint(equalToConstant: barHeight),
      editActionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])

    updateEditActionBarState()
  }

  private func makeActionBarButton(title: String, action: Selector) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = title
    config.cornerStyle = .medium
    config.buttonSize = .medium
    let button = UIButton(configuration: config)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.isEnabled = false
    return button
  }

  private func updateEditActionBarState() {
    let selectedCount = tableView.indexPathsForSelectedRows?
      .filter { $0.section == Section.playlists.rawValue }
      .count ?? 0
    let hasSelection = selectedCount > 0
    for button in editActionBarButtons {
      button.isEnabled = hasSelection
    }
  }

  // MARK: - Edit mode

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    editActionBar.isHidden = !editing
    tableView.contentInset.bottom = editing ? 50 : 0
    if editing {
      updateEditActionBarState()
    }
  }

  @objc
  private func addSelectedToFolder() {
    guard let selectedRows = tableView.indexPathsForSelectedRows else { return }
    let selectedPlaylistIds = selectedRows
      .filter { $0.section == Section.playlists.rawValue }
      .compactMap { displayedPlaylists[safe: $0.row]?.id }
    guard !selectedPlaylistIds.isEmpty else { return }
    presentFolderPicker(title: "Add to Folder") { [weak self] folderId in
      self?.folderStore.addPlaylists(selectedPlaylistIds, to: folderId)
      self?.setEditing(false, animated: true)
    }
  }

  @objc
  private func moveSelectedToFolder() {
    guard let currentFolderId = parentFolderId,
          let selectedRows = tableView.indexPathsForSelectedRows
    else { return }
    let selectedPlaylistIds = selectedRows
      .filter { $0.section == Section.playlists.rawValue }
      .compactMap { displayedPlaylists[safe: $0.row]?.id }
    guard !selectedPlaylistIds.isEmpty else { return }
    presentFolderPicker(title: "Move to Folder", excluding: currentFolderId) { [weak self] destId in
      for playlistId in selectedPlaylistIds {
        self?.folderStore.movePlaylist(playlistId, from: currentFolderId, to: destId)
      }
      self?.setEditing(false, animated: true)
    }
  }

  @objc
  private func removeSelectedFromFolder() {
    guard let currentFolderId = parentFolderId,
          let selectedRows = tableView.indexPathsForSelectedRows
    else { return }
    let selectedPlaylistIds = selectedRows
      .filter { $0.section == Section.playlists.rawValue }
      .compactMap { displayedPlaylists[safe: $0.row]?.id }
    guard !selectedPlaylistIds.isEmpty else { return }
    folderStore.removePlaylists(selectedPlaylistIds, from: currentFolderId)
    setEditing(false, animated: true)
  }

  // MARK: - Data loading

  private func reloadContent() {
    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
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
    var playlists = allPlaylists
      .filter { !$0.isSmartPlaylist && !filedIds.contains($0.id) }

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
    var playlists = allPlaylists.filter { ids.contains($0.id) }

    if !searchText.isEmpty {
      playlists = playlists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }

    return sortPlaylists(playlists)
  }

  private func sortPlaylists(_ playlists: [Playlist]) -> [Playlist] {
    switch sortType {
    case .name:
      return playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .lastPlayed:
      return playlists.sorted { ($0.lastTimePlayed ?? .distantPast) > ($1.lastTimePlayed ?? .distantPast) }
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
    cell.imageView?.image = UIImage(systemName: "folder.fill")
    cell.imageView?.tintColor = .systemBlue
    cell.textLabel?.text = folder.name
    let playlistCount = folder.allPlaylistIdsRecursive.count
    let subfolderCount = folder.subfolders.count
    var details = [String]()
    if playlistCount >
      0 { details.append("\(playlistCount) playlist\(playlistCount == 1 ? "" : "s")") }
    if subfolderCount >
      0 { details.append("\(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s")") }
    cell.detailTextLabel?.text = details.isEmpty ? "Empty" : details.joined(separator: ", ")
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = .disclosureIndicator
    cell.backgroundColor = .secondarySystemGroupedBackground
    return cell
  }

  private func playlistCell(for indexPath: IndexPath) -> UITableViewCell {
    let playlist = displayedPlaylists[indexPath.row]
    let cell: PlaylistTableCell = tableView.dequeueReusableCell(
      withIdentifier: PlaylistTableCell.typeName,
      for: indexPath
    ) as! PlaylistTableCell
    cell.display(playlist: playlist, rootView: self)
    return cell
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if isEditing {
      updateEditActionBarState()
      return
    }
    switch Section(rawValue: indexPath.section) {
    case .folders:
      let folder = displayedFolders[indexPath.row]
      let contentsVC = PlaylistFolderContentsVC(account: account, parentFolderId: folder.id)
      navigationController?.pushViewController(contentsVC, animated: true)
    case .playlists:
      let playlist = displayedPlaylists[indexPath.row]
      let detailVC = PlaylistDetailVC(account: account, playlist: playlist)
      navigationController?.pushViewController(detailVC, animated: true)
    case .none:
      break
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    if isEditing {
      updateEditActionBarState()
    }
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    switch Section(rawValue: indexPath.section) {
    case .playlists: return true
    default: return false
    }
  }

  // MARK: - Context menus

  override func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    switch Section(rawValue: indexPath.section) {
    case .folders:
      return folderContextMenu(at: indexPath)
    case .playlists:
      return playlistContextMenu(at: indexPath)
    case .none:
      return nil
    }
  }

  private func folderContextMenu(at indexPath: IndexPath) -> UIContextMenuConfiguration {
    let folder = displayedFolders[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      let renameAction = UIAction(
        title: "Rename",
        image: UIImage(systemName: "pencil")
      ) { [weak self] _ in
        self?.promptRenameFolder(folder)
      }
      let deleteAction = UIAction(
        title: "Delete Folder",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.confirmDeleteFolder(folder)
      }
      return UIMenu(children: [renameAction, deleteAction])
    }
  }

  private func playlistContextMenu(at indexPath: IndexPath) -> UIContextMenuConfiguration {
    let playlist = displayedPlaylists[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }
      var actions = [UIMenuElement]()

      if let currentFolderId = parentFolderId {
        actions.append(UIAction(
          title: "Move to Folder\u{2026}",
          image: UIImage(systemName: "folder")
        ) { [weak self] _ in
          self?.presentFolderPicker(title: "Move to Folder", excluding: currentFolderId) { destId in
            self?.folderStore.movePlaylist(playlist.id, from: currentFolderId, to: destId)
          }
        })

        actions.append(UIAction(
          title: "Also Show in Folder\u{2026}",
          image: UIImage(systemName: "folder.badge.plus")
        ) { [weak self] _ in
          self?
            .presentFolderPicker(
              title: "Also Show in Folder",
              excluding: currentFolderId
            ) { destId in
              self?.folderStore.addPlaylists([playlist.id], to: destId)
            }
        })

        actions.append(UIAction(
          title: "Remove from Folder",
          image: UIImage(systemName: "folder.badge.minus"),
          attributes: .destructive
        ) { [weak self] _ in
          self?.folderStore.removePlaylists([playlist.id], from: currentFolderId)
        })
      } else {
        actions.append(UIAction(
          title: "Add to Folder\u{2026}",
          image: UIImage(systemName: "folder.badge.plus")
        ) { [weak self] _ in
          self?.presentFolderPicker(title: "Add to Folder") { folderId in
            self?.folderStore.addPlaylists([playlist.id], to: folderId)
          }
        })
      }

      return UIMenu(children: actions)
    }
  }

  // MARK: - Folder management prompts

  private func promptCreateFolder() {
    let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.placeholder = "Folder name"
      textField.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
      guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
      self?.folderStore.createFolder(name: name, parent: self?.parentFolderId)
    })
    present(alert, animated: true)
  }

  private func promptRenameFolder(_ folder: PlaylistFolder) {
    let alert = UIAlertController(title: "Rename Folder", message: nil, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.text = folder.name
      textField.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
      guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
      self?.folderStore.renameFolder(id: folder.id, to: name)
    })
    present(alert, animated: true)
  }

  private func confirmDeleteFolder(_ folder: PlaylistFolder) {
    let subfolderCount = folder.subfolders.count
    let message: String
    if subfolderCount > 0 {
      message = "Delete \"\(folder.name)\" and its \(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s")? Playlists inside will become unfiled."
    } else {
      message = "Delete \"\(folder.name)\"? Playlists inside will become unfiled."
    }
    let alert = UIAlertController(title: "Delete Folder", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.folderStore.deleteFolder(id: folder.id)
    })
    present(alert, animated: true)
  }

  // MARK: - Folder picker

  private func presentFolderPicker(
    title: String,
    excluding excludedFolderId: UUID? = nil,
    completion: @escaping (UUID) -> ()
  ) {
    let allFolders = flattenFolders(folderStore.folders, depth: 0, excluding: excludedFolderId)

    let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

    for (folder, depth) in allFolders {
      let indent = String(repeating: "  ", count: depth)
      alert.addAction(UIAlertAction(title: "\(indent)\(folder.name)", style: .default) { _ in
        completion(folder.id)
      })
    }

    alert.addAction(UIAlertAction(title: "New Folder\u{2026}", style: .default) { [weak self] _ in
      let nameAlert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
      nameAlert.addTextField { $0.placeholder = "Folder name"; $0.autocapitalizationType = .words }
      nameAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      nameAlert.addAction(UIAlertAction(title: "Create", style: .default) { _ in
        guard let name = nameAlert.textFields?.first?.text, !name.isEmpty else { return }
        let newFolder = self?.folderStore.createFolder(name: name, parent: self?.parentFolderId)
        if let newFolder { completion(newFolder.id) }
      })
      self?.present(nameAlert, animated: true)
    })

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = alert.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
    }
    present(alert, animated: true)
  }

  private func flattenFolders(
    _ folders: [PlaylistFolder],
    depth: Int,
    excluding excludedId: UUID?
  )
    -> [(PlaylistFolder, Int)] {
    var result = [(PlaylistFolder, Int)]()
    for folder in folders {
      if folder.id == excludedId { continue }
      result.append((folder, depth))
      result.append(contentsOf: flattenFolders(
        folder.subfolders,
        depth: depth + 1,
        excluding: excludedId
      ))
    }
    return result
  }
}

// MARK: - UISearchResultsUpdating

extension PlaylistFolderContentsVC: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    reloadContent()
  }
}

// MARK: - Array safe subscript

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
