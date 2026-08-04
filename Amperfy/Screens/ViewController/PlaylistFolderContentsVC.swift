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

/// Shows the contents of a playlist folder, or the root level when
/// `parentFolderId` is nil. Replaces `PlaylistsVC` as the Playlists tab entry
/// point.
///
/// v3: one interleaved list of siblings (folders and playlists together, in the
/// order the user arranged them), built for bulk organization — multi-select
/// with command- and shift-click, drag and drop onto folders, keyboard commands,
/// and bulk toolbar/context-menu actions. The screen is designed around a Mac
/// Catalyst session where a whole folder tree is rebuilt in one sitting, while
/// staying usable with touch alone.
///
/// The list plumbing (rows, cells, search, sort, data loading) lives in
/// `PlaylistFolderBrowsingTableViewController`, shared with the "Add to
/// Playlist" picker (`PlaylistSelectorVC`). The bulk behaviour is split across:
/// - `PlaylistFolderContentsVC+BulkSelection.swift` — selection and bulk actions
/// - `PlaylistFolderContentsVC+DragAndDrop.swift` — drag, drop, reorder
/// - `PlaylistFolderContentsVC+Keyboard.swift` — key commands and focus
class PlaylistFolderContentsVC: PlaylistFolderBrowsingTableViewController {
  // MARK: - Init

  override init(account: Account, parentFolderId: UUID? = nil) {
    super.init(account: account, parentFolderId: parentFolderId)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Selection state

  /// The source of truth for what is selected. The table view is driven from
  /// this, not read as the answer — see `PlaylistFolderSelectionModel`.
  var selectionModel = PlaylistFolderSelectionModel()
  /// Modifier keys currently held, so a click can be classified as plain,
  /// command- or shift-click on Catalyst and iPad.
  var modifierKeyState = PlaylistFolderModifierKeyState()
  /// True between drag start and drag end, so a spring-loaded row activation is
  /// understood as "descend into this folder" rather than as a selection tap.
  var isDraggingRows = false

  // MARK: - Floating action bar

  let editActionBar = UIView()
  var editActionBarButtons: [UIButton] = []
  var selectionCountLabel: UILabel?

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

    configureDragAndDrop()

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

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Needed for `keyCommands` to reach this screen rather than stopping at the
    // window; without it every shortcut below is dead on Mac.
    becomeFirstResponder()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // A modifier released while another screen is up would never be seen, so a
    // stale "command is down" must not survive leaving this list.
    modifierKeyState.reset()
  }

  // MARK: - Navigation items

  func rebuildNavigationItems() {
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

  // MARK: - Browsing hooks

  override func makeChildBrowser(parentFolderId: UUID) -> UITableViewController {
    PlaylistFolderContentsVC(account: account, parentFolderId: parentFolderId)
  }

  override func onPlaylistSelected(_ playlist: Playlist, at indexPath: IndexPath) {
    let detailVC = PlaylistDetailVC(account: account, playlist: playlist)
    navigationController?.pushViewController(detailVC, animated: true)
  }

  /// Row indices are only meaningful against the list they were taken from, so
  /// the selection is reconciled against the freshly built one.
  ///
  /// Lives here rather than beside the rest of the selection code because Swift
  /// will not let a non-`@objc` method be overridden from an extension.
  override func didReloadRows() {
    selectionModel.reconcile(rowCount: displayedRows.count)
    applySelectionToTableView()
  }

  // MARK: - Row editing

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    row(at: indexPath) != nil
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    deleteRow(at: indexPath.row)
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    guard let row = row(at: indexPath) else { return nil }
    let deleteAction: UIContextualAction
    switch row {
    case let .folder(folder):
      deleteAction = UIContextualAction(
        style: .destructive,
        title: "Delete"
      ) { [weak self] _, _, completion in
        self?.handleFolderDelete(folder)
        completion(true)
      }
    case let .playlist(playlist):
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
    }
    deleteAction.image = UIImage(systemName: "trash")
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }

  /// Delete whatever sits at `rowIndex`, routing folders and playlists to their
  /// own confirmation flows.
  func deleteRow(at rowIndex: Int) {
    switch row(at: rowIndex) {
    case let .folder(folder): handleFolderDelete(folder)
    case let .playlist(playlist): confirmDeletePlaylist(playlist)
    case .none: break
    }
  }

  /// Entry point shared by swipe, edit-mode commit, the context menu and the
  /// delete key. Empty folders delete immediately; non-empty folders go through
  /// `confirmDeleteFolder`.
  func handleFolderDelete(_ folder: PlaylistFolder) {
    if folder.playlistIds.isEmpty, folder.subfolders.isEmpty {
      folderStore.deleteFolder(id: folder.id)
    } else {
      confirmDeleteFolder(folder)
    }
  }

  // MARK: - Folder management prompts

  func promptCreatePlaylist() {
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

  func promptCreateFolder() {
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

  func promptRenameFolder(_ folder: PlaylistFolder) {
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

  func promptRenamePlaylist(_ playlist: Playlist) {
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

  func confirmDeletePlaylist(_ playlist: Playlist) {
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
  func deletePlaylist(_ playlist: Playlist) {
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

  func confirmDeleteFolder(_ folder: PlaylistFolder) {
    let message = deleteFolderConfirmationMessage(
      folderName: folder.name,
      playlistCount: folder.playlistIds.count,
      subfolderCount: folder.subfolders.count
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
  func deleteFolderConfirmationMessage(
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

  /// Present the destination picker. `excludingSelectedFolders` keeps the
  /// folders being moved (and their subtrees) out of the list, since either
  /// would be a cycle.
  func presentFolderPicker(
    title: String,
    includesRootDestination: Bool,
    excludingFolderIds excludedFolderIds: Set<UUID> = [],
    onDestinationChosen: @escaping (UUID?) -> ()
  ) {
    let pickerVC = PlaylistFolderPickerVC(
      promptTitle: title,
      includesRootDestination: includesRootDestination,
      excludedFolderIds: excludedFolderIds,
      onDestinationChosen: onDestinationChosen
    )
    let navigationVC = UINavigationController(rootViewController: pickerVC)
    present(navigationVC, animated: true)
  }
}
