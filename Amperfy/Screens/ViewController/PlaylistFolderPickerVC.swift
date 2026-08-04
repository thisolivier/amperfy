//
//  PlaylistFolderPickerVC.swift
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

// MARK: - PlaylistFolderPickerVC

/// Destination picker for the bulk "Move to Folder…" / "Add to Folder…"
/// actions: the whole folder tree, flattened and indented, in a searchable
/// table.
///
/// This replaces the action sheet the single-item actions used. An action sheet
/// is fine for the handful of folders a fresh library has and unusable for the
/// tree this feature exists to rebuild — it has no search, no scrolling to speak
/// of on Mac, and it truncates. Presented pushed inside a nav controller so the
/// picker gets a Cancel button and a title saying which action is being
/// completed.
class PlaylistFolderPickerVC: UITableViewController {
  // MARK: - Types

  /// One selectable destination. A `nil` folder is the root level.
  private struct DestinationEntry {
    let folder: PlaylistFolder?
    let depth: Int

    var name: String { folder?.name ?? "Playlists (Top Level)" }
    var folderId: String? { folder?.id }
  }

  // MARK: - Properties

  private let folderStore = PlaylistFolderStore.shared
  private let promptTitle: String
  private let includesRootDestination: Bool
  /// Folders that must not be offered — the folders being moved, and everything
  /// beneath them, since either would be a cycle.
  private let excludedFolderIds: Set<String>
  private let onDestinationChosen: (String?) -> ()

  private var allDestinations: [DestinationEntry] = []
  private var displayedDestinations: [DestinationEntry] = []
  private var searchText = ""

  private lazy var searchController: UISearchController = {
    let controller = UISearchController(searchResultsController: nil)
    controller.searchResultsUpdater = self
    controller.obscuresBackgroundDuringPresentation = false
    controller.searchBar.placeholder = "Search Folders"
    return controller
  }()

  // MARK: - Init

  init(
    promptTitle: String,
    includesRootDestination: Bool,
    excludedFolderIds: Set<String> = [],
    onDestinationChosen: @escaping (String?) -> ()
  ) {
    self.promptTitle = promptTitle
    self.includesRootDestination = includesRootDestination
    self.excludedFolderIds = excludedFolderIds
    self.onDestinationChosen = onDestinationChosen
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = promptTitle
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel,
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "New Folder\u{2026}",
      primaryAction: UIAction { [weak self] _ in self?.promptCreateDestinationFolder() }
    )

    rebuildDestinations()
  }

  // MARK: - Data

  private func rebuildDestinations() {
    var destinations = [DestinationEntry]()
    if includesRootDestination {
      destinations.append(DestinationEntry(folder: nil, depth: 0))
    }
    destinations.append(contentsOf: flattened(folderStore.folders, depth: 0))
    allDestinations = destinations
    applySearchFilter()
  }

  /// Depth-first walk, skipping excluded folders *and* their subtrees — a folder
  /// inside one of the folders being moved is just as illegal a destination as
  /// the moved folder itself.
  private func flattened(_ folders: [PlaylistFolder], depth: Int) -> [DestinationEntry] {
    var result = [DestinationEntry]()
    for folder in folders {
      guard !excludedFolderIds.contains(folder.id) else { continue }
      result.append(DestinationEntry(folder: folder, depth: depth))
      result.append(contentsOf: flattened(folder.subfolders, depth: depth + 1))
    }
    return result
  }

  private func applySearchFilter() {
    if searchText.isEmpty {
      displayedDestinations = allDestinations
    } else {
      displayedDestinations = allDestinations.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }
    tableView.reloadData()
  }

  // MARK: - New folder

  private func promptCreateDestinationFolder() {
    let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
    let createAction = UIAlertAction(
      title: "Create",
      style: .default
    ) { [weak self, weak alert] _ in
      guard let self,
            let name = alert?.textFields?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { return }
      // The new folder is created at the root: it is a destination being
      // invented mid-flow, and nesting it somewhere the user has not pointed at
      // would be a guess.
      let newFolder = folderStore.createFolder(name: name, parent: nil)
      choose(folderId: newFolder.id)
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

  private func choose(folderId: String?) {
    let completion = onDestinationChosen
    dismiss(animated: true) { completion(folderId) }
  }

  // MARK: - UITableViewDataSource

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    displayedDestinations.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let destination = displayedDestinations[indexPath.row]
    let cell = UITableViewCell(style: .default, reuseIdentifier: "FolderDestinationCell")
    var configuration = cell.defaultContentConfiguration()
    configuration.text = destination.name
    configuration.image = UIImage(
      systemName: destination.folder == nil ? "music.note.list" : "folder"
    )
    // Indentation is only meaningful while the full tree is shown; a search
    // result list has no parents to indent under.
    configuration.directionalLayoutMargins.leading += searchText.isEmpty
      ? CGFloat(destination.depth) * 16
      : 0
    cell.contentConfiguration = configuration
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    choose(folderId: displayedDestinations[indexPath.row].folderId)
  }
}

// MARK: UISearchResultsUpdating

extension PlaylistFolderPickerVC: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    applySearchFilter()
  }
}
