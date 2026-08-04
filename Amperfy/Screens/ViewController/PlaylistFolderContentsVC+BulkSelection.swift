//
//  PlaylistFolderContentsVC+BulkSelection.swift
//  Amperfy
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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
import UIKit

/// Multi-select and the bulk actions that operate on it.
///
/// Selection is held in `selectionModel` and pushed onto the table view, rather
/// than read back out of `indexPathsForSelectedRows`. That inversion is what
/// makes command-click, shift-click ranges and keyboard-driven selection
/// possible at all: each needs an anchor and a focused row, neither of which
/// UIKit's table selection carries.
extension PlaylistFolderContentsVC {
  // MARK: - Selected rows

  /// The rows currently selected, in list order.
  var selectedRows: [PlaylistFolderBrowseRow] {
    selectionModel.orderedSelectedRowIndices.compactMap { row(at: $0) }
  }

  var selectedFolderIds: [String] {
    selectedRows.compactMap { $0.asFolder?.id }
  }

  var selectedPlaylistIds: [String] {
    selectedRows.compactMap { $0.asPlaylist?.id }
  }

  /// Every folder in the selection plus everything beneath it — the set that
  /// must not be offered as a move destination.
  var selectedFolderSubtreeIds: Set<String> {
    var result = Set<String>()
    for folder in selectedRows.compactMap(\.asFolder) {
      collectFolderSubtreeIds(folder, into: &result)
    }
    return result
  }

  private func collectFolderSubtreeIds(_ folder: PlaylistFolder, into result: inout Set<String>) {
    result.insert(folder.id)
    for subfolder in folder.subfolders {
      collectFolderSubtreeIds(subfolder, into: &result)
    }
  }

  // MARK: - Driving the table from the model

  /// Bring the table view's selection in line with the model.
  func applySelectionToTableView() {
    let selectedRowIndices = selectionModel.selectedRowIndices
    let selectedIndexPaths = Set(tableView.indexPathsForSelectedRows ?? [])
    for rowIndex in displayedRows.indices {
      let indexPath = IndexPath(row: rowIndex, section: 0)
      let shouldBeSelected = selectedRowIndices.contains(rowIndex)
      let isSelected = selectedIndexPaths.contains(indexPath)
      if shouldBeSelected, !isSelected {
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
      } else if !shouldBeSelected, isSelected {
        tableView.deselectRow(at: indexPath, animated: false)
      }
    }
    updateEditActionBarState()
  }

  // MARK: - Edit mode

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    editActionBar.isHidden = !editing
    tableView.contentInset.bottom = editing ? Self.editActionBarHeight : 0
    if !editing {
      selectionModel.clearSelection()
    }
    applySelectionToTableView()
    rebuildNavigationItems()
  }

  /// Enter multi-select because the user command- or shift-clicked outside edit
  /// mode, and apply that click. Without this, reaching multi-select on Mac
  /// would mean finding "Select Items" in a menu first.
  func beginSelection(with gesture: PlaylistFolderSelectionGesture, atRowIndex rowIndex: Int) {
    if !isEditing { setEditing(true, animated: true) }
    selectionModel.applyGesture(gesture, atRowIndex: rowIndex)
    applySelectionToTableView()
  }

  // MARK: - Selection taps

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    // A spring-loaded activation during a drag means "descend into this folder",
    // whatever mode the list is in.
    if isDraggingRows, let folder = row(at: indexPath)?.asFolder {
      tableView.deselectRow(at: indexPath, animated: false)
      openFolder(folder)
      return
    }

    if isEditing {
      let gesture: PlaylistFolderSelectionGesture = modifierKeyState.isShiftKeyDown
        ? .extendFromAnchor
        : .toggle
      selectionModel.applyGesture(gesture, atRowIndex: indexPath.row)
      applySelectionToTableView()
      return
    }

    if modifierKeyState.isSelectionModifierHeld {
      beginSelection(with: modifierKeyState.selectionGesture, atRowIndex: indexPath.row)
      return
    }

    selectionModel.setFocusedRowIndex(indexPath.row)
    super.tableView(tableView, didSelectRowAt: indexPath)
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    guard isEditing else { return }
    // UIKit deselects on a second tap; mirror that as a toggle so the model and
    // the table never disagree.
    if modifierKeyState.isShiftKeyDown {
      selectionModel.applyGesture(.extendFromAnchor, atRowIndex: indexPath.row)
    } else {
      selectionModel.applyGesture(.toggle, atRowIndex: indexPath.row)
    }
    applySelectionToTableView()
  }

  // MARK: - Floating action bar

  static let editActionBarHeight: CGFloat = 68

  func configureEditActionBar() {
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

    var actionBarButtons = [
      makeActionBarButton(title: "Move\u{2026}", action: #selector(moveSelectionToFolder)),
      makeActionBarButton(title: "Add to\u{2026}", action: #selector(addSelectionToFolder)),
      makeActionBarButton(title: "New Folder", action: #selector(newFolderFromSelection)),
    ]
    if parentFolderId != nil {
      actionBarButtons.append(
        makeActionBarButton(title: "Remove", action: #selector(removeSelectionFromFolder))
      )
    }
    for button in actionBarButtons {
      stackView.addArrangedSubview(button)
    }
    editActionBarButtons = actionBarButtons

    NSLayoutConstraint.activate([
      editActionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editActionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editActionBar.heightAnchor.constraint(equalToConstant: Self.editActionBarHeight),
      editActionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])

    updateEditActionBarState()
  }

  private func makeActionBarButton(title: String, action: Selector) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.cornerStyle = .medium
    configuration.buttonSize = .medium
    let button = UIButton(configuration: configuration)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.isEnabled = false
    return button
  }

  func updateEditActionBarState() {
    let selectedCount = selectionModel.selectedRowCount
    for button in editActionBarButtons {
      button.isEnabled = selectedCount > 0
    }
    selectionCountLabel?.text = selectedCount == 1 ? "1 selected" : "\(selectedCount) selected"
  }

  // MARK: - Bulk actions

  @objc
  func moveSelectionToFolder() {
    let folderIds = selectedFolderIds
    let playlistIds = selectedPlaylistIds
    guard !folderIds.isEmpty || !playlistIds.isEmpty else { return }
    presentFolderPicker(
      title: "Move to Folder",
      // The root is a legitimate destination for a move out of a folder, and for
      // a re-parent at any level.
      includesRootDestination: true,
      excludingFolderIds: selectedFolderSubtreeIds
    ) { [weak self] destinationFolderId in
      guard let self else { return }
      folderStore.moveSiblings(
        folderIds: folderIds,
        playlistIds: playlistIds,
        from: parentFolderId,
        to: destinationFolderId
      )
      setEditing(false, animated: true)
    }
  }

  @objc
  func addSelectionToFolder() {
    let playlistIds = selectedPlaylistIds
    // A folder has exactly one parent, so "also show in" has no meaning for one.
    // Rather than silently doing nothing, say so.
    guard !playlistIds.isEmpty else {
      presentSelectionNotice(
        title: "Playlists Only",
        message: "Folders live in one place at a time. Use Move to relocate a folder."
      )
      return
    }
    presentFolderPicker(
      title: "Add to Folder",
      includesRootDestination: false
    ) { [weak self] destinationFolderId in
      guard let self, let destinationFolderId else { return }
      folderStore.addPlaylistsToAdditionalFolder(playlistIds, folderId: destinationFolderId)
      setEditing(false, animated: true)
    }
  }

  @objc
  func removeSelectionFromFolder() {
    guard let currentFolderId = parentFolderId else { return }
    let playlistIds = selectedPlaylistIds
    guard !playlistIds.isEmpty else {
      presentSelectionNotice(
        title: "Playlists Only",
        message: "Use Move to take a folder out of this one."
      )
      return
    }
    folderStore.removePlaylists(playlistIds, from: currentFolderId)
    setEditing(false, animated: true)
  }

  @objc
  func newFolderFromSelection() {
    let folderIds = selectedFolderIds
    let playlistIds = selectedPlaylistIds
    guard !folderIds.isEmpty || !playlistIds.isEmpty else { return }

    let alert = UIAlertController(
      title: "New Folder from Selection",
      message: nil,
      preferredStyle: .alert
    )
    let createAction = UIAlertAction(
      title: "Create",
      style: .default
    ) { [weak self, weak alert] _ in
      guard let self,
            let name = alert?.textFields?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { return }
      folderStore.createFolder(
        named: name,
        in: parentFolderId,
        movingFolders: folderIds,
        playlists: playlistIds
      )
      setEditing(false, animated: true)
    }
    createAction.isEnabled = false
    alert.addTextField { textField in
      textField.placeholder = "Folder name"
      textField.autocapitalizationType = .words
      textField.addAction(UIAction { [weak createAction, weak textField] _ in
        let trimmedName = textField?.text?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        createAction?.isEnabled = !trimmedName.isEmpty
      }, for: .editingChanged)
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(createAction)
    present(alert, animated: true)
  }

  @objc
  func deleteSelection() {
    let rowsToDelete = selectedRows
    guard !rowsToDelete.isEmpty else { return }
    if rowsToDelete.count == 1 {
      // One item gets its own tailored confirmation, including the folder's
      // flatten-on-delete explanation.
      switch rowsToDelete[0] {
      case let .folder(folder): handleFolderDelete(folder)
      case let .playlist(playlist): confirmDeletePlaylist(playlist)
      }
      return
    }

    let folderCount = rowsToDelete.compactMap(\.asFolder).count
    let playlistCount = rowsToDelete.count - folderCount
    let alert = UIAlertController(
      title: "Delete \(rowsToDelete.count) Items",
      message: bulkDeleteMessage(folderCount: folderCount, playlistCount: playlistCount),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      guard let self else { return }
      folderStore.performBatchedUpdates {
        for folder in rowsToDelete.compactMap(\.asFolder) {
          folderStore.deleteFolder(id: folder.id)
        }
      }
      for playlist in rowsToDelete.compactMap(\.asPlaylist) {
        deletePlaylist(playlist)
      }
      setEditing(false, animated: true)
    })
    present(alert, animated: true)
  }

  private func bulkDeleteMessage(folderCount: Int, playlistCount: Int) -> String {
    var fragments = [String]()
    if folderCount > 0 {
      fragments.append(
        "\(folderCount) folder\(folderCount == 1 ? "" : "s") — their contents move up one level"
      )
    }
    if playlistCount > 0 {
      fragments.append(
        "\(playlistCount) playlist\(playlistCount == 1 ? "" : "s") — deleted from all your devices"
      )
    }
    return fragments.joined(separator: ".\n") + "."
  }

  private func presentSelectionNotice(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
