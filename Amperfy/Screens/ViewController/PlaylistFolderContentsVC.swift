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
///
/// The folder-aware list plumbing (sections, cells, search, sort, data loading)
/// lives in `PlaylistFolderBrowsingTableViewController`, shared with the
/// "Add to Playlist" picker (`PlaylistSelectorVC`).
class PlaylistFolderContentsVC: PlaylistFolderBrowsingTableViewController {
  // MARK: - Init

  override init(account: Account, parentFolderId: UUID? = nil) {
    super.init(account: account, parentFolderId: parentFolderId)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Floating action bar

  private let editActionBar = UIView()
  private var editActionBarButtons: [UIButton] = []
  private var selectionCountLabel: UILabel?
  private var editActionBarBottomConstraint: NSLayoutConstraint?

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
      title = folder.name
    } else {
      title = "Playlists"
      navigationItem.largeTitleDisplayMode = .always
    }

    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = UITableView.automaticDimension
    tableView.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemGroupedBackground
    tableView.allowsMultipleSelectionDuringEditing = true

    navigationItem.searchController = searchController
    definesPresentationContext = true

    configureEditActionBar()
    rebuildNavigationItems()

    startObservingFolderChanges()
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
    let optionsButton = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      menu: UIMenu.lazyMenu { [weak self] in
        guard let self else { return [] }

        let selectItemsAction = UIAction(
          title: isEditing ? "Done" : "Select Items",
          image: UIImage(systemName: "checkmark.circle")
        ) { [weak self] _ in
          guard let self else { return }
          setEditing(!isEditing, animated: true)
        }

        let addPlaylistAction = UIAction(
          title: "Create Playlist",
          image: UIImage(systemName: "music.note.list")
        ) { [weak self] _ in
          self?.promptCreatePlaylist()
        }

        let addFolderAction = UIAction(
          title: "New Folder",
          image: UIImage(systemName: "folder.badge.plus")
        ) { [weak self] _ in
          self?.promptCreateFolder()
        }

        return [selectItemsAction, addPlaylistAction, addFolderAction, createSortButtonMenu()]
      }
    )

    navigationItem.rightBarButtonItems = [optionsButton]
  }

  override func rebuildNavigationItemsForSortChange() {
    rebuildNavigationItems()
  }

  // MARK: - Floating action bar

  private func configureEditActionBar() {
    editActionBar.translatesAutoresizingMaskIntoConstraints = false
    editActionBar.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground
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

    let countLabel = UILabel()
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .preferredFont(forTextStyle: .caption1)
    countLabel.textColor = ThemeStore.shared.dynamicSecondaryText ?? .secondaryLabel
    countLabel.textAlignment = .center
    countLabel.text = "0 selected"
    editActionBar.addSubview(countLabel)
    selectionCountLabel = countLabel

    let stackView = UIStackView()
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.distribution = .fillEqually
    stackView.spacing = 12
    editActionBar.addSubview(stackView)

    NSLayoutConstraint.activate([
      countLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
      countLabel.centerXAnchor.constraint(equalTo: editActionBar.centerXAnchor),
      stackView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
      stackView.leadingAnchor.constraint(equalTo: editActionBar.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: editActionBar.trailingAnchor, constant: -16),
      stackView.bottomAnchor.constraint(equalTo: editActionBar.bottomAnchor, constant: -8),
    ])

    if parentFolderId != nil {
      let moveButton = makeActionBarButton(
        title: "Move to Folder",
        action: #selector(moveSelectedToFolder)
      )
      let removeButton = makeActionBarButton(
        title: "Remove from Folder",
        action: #selector(removeSelectedFromFolder)
      )
      stackView.addArrangedSubview(moveButton)
      stackView.addArrangedSubview(removeButton)
      editActionBarButtons = [moveButton, removeButton]
    } else {
      let addButton = makeActionBarButton(
        title: "Add to Folder",
        action: #selector(addSelectedToFolder)
      )
      stackView.addArrangedSubview(addButton)
      editActionBarButtons = [addButton]
    }

    let barHeight: CGFloat = 68

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
    selectionCountLabel?.text = "\(selectedCount) selected"
  }

  // MARK: - Edit mode

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    editActionBar.isHidden = !editing
    tableView.contentInset.bottom = editing ? 68 : 0
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

  // MARK: - Browsing hooks

  override func makeChildBrowser(parentFolderId: UUID) -> UITableViewController {
    PlaylistFolderContentsVC(account: account, parentFolderId: parentFolderId)
  }

  override func onPlaylistSelected(_ playlist: Playlist, at indexPath: IndexPath) {
    let detailVC = PlaylistDetailVC(account: account, playlist: playlist)
    navigationController?.pushViewController(detailVC, animated: true)
  }

  override func shouldInterceptSelection(at indexPath: IndexPath) -> Bool {
    if isEditing {
      updateEditActionBarState()
      return true
    }
    return false
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    if isEditing {
      updateEditActionBarState()
    }
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    switch Section(rawValue: indexPath.section) {
    case .playlists: return true
    case .folders: return true
    case .none: return false
    }
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    switch Section(rawValue: indexPath.section) {
    case .folders:
      guard let folder = displayedFolders[safe: indexPath.row] else { return }
      handleFolderDelete(folder)
    case .playlists:
      guard let playlist = displayedPlaylists[safe: indexPath.row] else { return }
      confirmDeletePlaylist(playlist)
    case .none:
      break
    }
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    let deleteAction: UIContextualAction
    switch Section(rawValue: indexPath.section) {
    case .folders:
      guard let folder = displayedFolders[safe: indexPath.row] else { return nil }
      deleteAction = UIContextualAction(
        style: .destructive,
        title: "Delete"
      ) { [weak self] _, _, completion in
        self?.handleFolderDelete(folder)
        completion(true)
      }
    case .playlists:
      guard let playlist = displayedPlaylists[safe: indexPath.row] else { return nil }
      // completion(false): leave the row in place until the user confirms;
      // `deletePlaylist` calls `reloadContent()` to remove it on success, so a
      // cancelled confirmation doesn't animate away a row that still exists.
      deleteAction = UIContextualAction(
        style: .destructive,
        title: "Delete"
      ) { [weak self] _, _, completion in
        self?.confirmDeletePlaylist(playlist)
        completion(false)
      }
    case .none:
      return nil
    }
    deleteAction.image = UIImage(systemName: "trash")
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }

  /// Entry point shared by swipe, edit-mode commit, and context menu.
  /// Empty folders delete immediately; non-empty folders go through
  /// `confirmDeleteFolder`.
  private func handleFolderDelete(_ folder: PlaylistFolder) {
    if folder.playlistIds.isEmpty, folder.subfolders.isEmpty {
      folderStore.deleteFolder(id: folder.id)
    } else {
      confirmDeleteFolder(folder)
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
        self?.handleFolderDelete(folder)
      }
      return UIMenu(children: [renameAction, deleteAction])
    }
  }

  private func playlistContextMenu(at indexPath: IndexPath) -> UIContextMenuConfiguration {
    let playlist = displayedPlaylists[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }
      var actions = [UIMenuElement]()

      actions.append(UIAction(
        title: "Rename",
        image: UIImage(systemName: "pencil")
      ) { [weak self] _ in
        self?.promptRenamePlaylist(playlist)
      })

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

      actions.append(UIAction(
        title: "Delete Playlist",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.confirmDeletePlaylist(playlist)
      })

      return UIMenu(children: actions)
    }
  }

  // MARK: - Folder management prompts

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
      createPlaylist(named: name)
    })
    present(alert, animated: true)
  }

  /// Creates a playlist, files it into the current folder when this view is
  /// folder-scoped, syncs the new name to the server when online, and reloads.
  private func createPlaylist(named name: String) {
    let library = appDelegate.storage.main.library
    let playlist = library.createPlaylist(account: account)
    playlist.name = name
    appDelegate.storage.main.saveContext()

    if let parentFolderId {
      folderStore.addPlaylists([playlist.id], to: parentFolderId)
    }

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

  private func promptRenamePlaylist(_ playlist: Playlist) {
    let currentName = playlist.name
    let alert = UIAlertController(title: "Rename Playlist", message: nil, preferredStyle: .alert)
    let renameAction = UIAlertAction(
      title: "Rename",
      style: .default
    ) { [weak self, weak alert] _ in
      guard let self,
            let newName = alert?.textFields?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !newName.isEmpty, newName != currentName,
            let account = playlist.account
      else { return }
      Task { @MainActor in
        do {
          try await self.appDelegate.getMeta(account.info).renamePlaylist(playlist, to: newName)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Playlist Update Name", error: error)
        }
        self.reloadContent()
      }
    }
    // Keep Rename disabled until the name is non-empty and actually changed —
    // matches the New-Playlist dialog's Create button, and a same-name rename is
    // a no-op anyway.
    renameAction.isEnabled = false
    alert.addTextField { textField in
      textField.text = currentName
      textField.autocapitalizationType = .words
      textField.clearButtonMode = .whileEditing
      textField.addAction(UIAction { [weak renameAction, weak textField] _ in
        let trimmed = textField?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        renameAction?.isEnabled = !trimmed.isEmpty && trimmed != currentName
      }, for: .editingChanged)
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(renameAction)
    present(alert, animated: true)
  }

  private func confirmDeletePlaylist(_ playlist: Playlist) {
    let alert = UIAlertController(
      title: "Delete Playlist",
      message: "Delete \u{201C}\(playlist.name)\u{201D}? This removes it from all your synced devices.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete Playlist", style: .destructive) { [weak self] _ in
      self?.deletePlaylist(playlist)
    })
    present(alert, animated: true)
  }

  /// Deletes a playlist locally, persists, then tells the server. The server
  /// upload is essential: without it the next `syncDownPlaylistsWithoutSongs()`
  /// re-creates the playlist, so the deletion would not stick.
  private func deletePlaylist(_ playlist: Playlist) {
    let playlistId = playlist.id
    let account = playlist.account
    appDelegate.storage.main.library.deletePlaylist(playlist)
    appDelegate.storage.main.saveContext()
    reloadContent()

    guard let account else { return }
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistIdToDelete: playlistId)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Deletion", error: error)
      }
    }
  }

  private func confirmDeleteFolder(_ folder: PlaylistFolder) {
    let playlistCount = folder.playlistIds.count
    let subfolderCount = folder.subfolders.count
    let message = deleteFolderConfirmationMessage(
      folderName: folder.name,
      playlistCount: playlistCount,
      subfolderCount: subfolderCount
    )
    let alert = UIAlertController(title: "Delete Folder", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete Folder", style: .destructive) { [weak self] _ in
      self?.folderStore.deleteFolder(id: folder.id)
    })
    present(alert, animated: true)
  }

  /// Copy for the flatten-on-delete confirmation alert. Handles singular/plural
  /// for both playlists and sub-folders, and trims either half when the count
  /// is zero. Counts reflect *direct* children only (grandchildren stay inside
  /// their direct parent, which itself pops up one level).
  private func deleteFolderConfirmationMessage(
    folderName: String,
    playlistCount: Int,
    subfolderCount: Int
  )
    -> String {
    let playlistFragment = playlistCount == 1
      ? "1 playlist"
      : "\(playlistCount) playlists"
    let subfolderFragment = subfolderCount == 1
      ? "1 sub-folder"
      : "\(subfolderCount) sub-folders"

    let childrenPhrase: String
    switch (playlistCount, subfolderCount) {
    case (0, 0):
      // Empty folders skip confirmation entirely (handled in
      // `handleFolderDelete`) — this branch is defensive only.
      return "Delete folder '\(folderName)'?"
    case (_, 0):
      childrenPhrase = "The \(playlistFragment) inside will move to the parent level."
    case (0, _):
      childrenPhrase = "The \(subfolderFragment) inside will move to the parent level."
    default:
      childrenPhrase =
        "The \(playlistFragment) and \(subfolderFragment) inside will move to the parent level."
    }
    return "Delete folder '\(folderName)'? \(childrenPhrase)"
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

// MARK: - Array safe subscript

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
