//
//  PlaylistFolderContentsVC+ContextMenu.swift
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

/// Row context menus — long-press on touch, right-click on Mac.
///
/// The menu is selection-aware: right-clicking a row that is part of a
/// multi-selection acts on the whole selection, which is the behaviour every
/// desktop file manager has and the thing that makes right-click worth reaching
/// for during a bulk reorganization.
extension PlaylistFolderContentsVC {
  override func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let row = row(at: indexPath) else { return nil }

    let isRowInMultiSelection = selectionModel.selectedRowIndices.contains(indexPath.row)
      && selectionModel.selectedRowCount > 1
    if isRowInMultiSelection {
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        UIMenu(children: self?.bulkSelectionMenuActions() ?? [])
      }
    }

    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      UIMenu(children: self?.singleRowMenuActions(for: row) ?? [])
    }
  }

  // MARK: - Bulk menu

  private func bulkSelectionMenuActions() -> [UIMenuElement] {
    let selectedCount = selectionModel.selectedRowCount
    var actions = [UIMenuElement]()

    actions.append(UIAction(
      title: "Move \(selectedCount) Items to Folder\u{2026}",
      image: UIImage(systemName: "folder")
    ) { [weak self] _ in
      self?.moveSelectionToFolder()
    })

    actions.append(UIAction(
      title: "Also Show in Folder\u{2026}",
      image: UIImage(systemName: "folder.badge.plus")
    ) { [weak self] _ in
      self?.addSelectionToFolder()
    })

    actions.append(UIAction(
      title: "New Folder from Selection\u{2026}",
      image: UIImage(systemName: "folder.badge.plus")
    ) { [weak self] _ in
      self?.newFolderFromSelection()
    })

    // No separate "Remove from This Folder" entry: for a playlists-only
    // selection the action below *is* that, and naming the same operation twice
    // in one menu invites the reading that they differ.
    //
    // Named for what it does, not for the key that reaches it: folders go,
    // playlists come out of this folder and stay in the library.
    actions.append(UIAction(
      title: bulkDeleteActionTitle(),
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { [weak self] _ in
      self?.deleteSelection()
    })

    return actions
  }

  /// Title for the bulk delete entry, which reads differently depending on what
  /// is actually in the selection.
  private func bulkDeleteActionTitle() -> String {
    let folderCount = selectedRows.compactMap(\.asFolder).count
    let playlistCount = selectedRows.count - folderCount
    switch (folderCount, playlistCount) {
    case (0, _):
      return playlistCount == 1
        ? "Remove from This Folder"
        : "Remove \(playlistCount) Playlists from This Folder"
    case (_, 0):
      return folderCount == 1 ? "Delete Folder" : "Delete \(folderCount) Folders"
    default:
      return "Delete \(folderCount) Folders, Remove \(playlistCount) Playlists"
    }
  }

  // MARK: - Single-row menu

  private func singleRowMenuActions(for row: PlaylistFolderBrowseRow) -> [UIMenuElement] {
    switch row {
    case let .folder(folder): return folderMenuActions(for: folder)
    case let .playlist(playlist): return playlistMenuActions(for: playlist)
    }
  }

  private func folderMenuActions(for folder: PlaylistFolder) -> [UIMenuElement] {
    var subtreeIds = Set<String>()
    collectSubtreeIds(folder, into: &subtreeIds)
    // `PlaylistFolder` is not Sendable, and the picker's completion escapes;
    // the id is all the move needs, and it is.
    let folderId = folder.id

    return [
      UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in
        self?.promptRenameFolder(folder)
      },
      UIAction(
        title: "Move to Folder\u{2026}",
        image: UIImage(systemName: "folder")
      ) { [weak self] _ in
        guard let self else { return }
        presentFolderPicker(
          title: "Move Folder",
          includesRootDestination: true,
          excludingFolderIds: subtreeIds
        ) { [weak self] destinationFolderId in
          self?.folderStore.moveFolders([folderId], toParent: destinationFolderId)
        }
      },
      UIAction(
        title: "Delete Folder",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.handleFolderDelete(folder)
      },
    ]
  }

  private func collectSubtreeIds(_ folder: PlaylistFolder, into result: inout Set<String>) {
    result.insert(folder.id)
    for subfolder in folder.subfolders {
      collectSubtreeIds(subfolder, into: &result)
    }
  }

  private func playlistMenuActions(for playlist: Playlist) -> [UIMenuElement] {
    var actions = [UIMenuElement]()

    actions.append(UIAction(
      title: "Rename",
      image: UIImage(systemName: "pencil")
    ) { [weak self] _ in
      self?.promptRenamePlaylist(playlist)
    })

    actions.append(UIAction(
      title: "Move to Folder\u{2026}",
      image: UIImage(systemName: "folder")
    ) { [weak self] _ in
      guard let self else { return }
      presentFolderPicker(
        title: "Move to Folder",
        includesRootDestination: parentFolderId != nil
      ) { [weak self] destinationFolderId in
        guard let self else { return }
        folderStore.movePlaylists(
          [playlist.id],
          from: parentFolderId,
          to: destinationFolderId
        )
      }
    })

    actions.append(UIAction(
      title: "Also Show in Folder\u{2026}",
      image: UIImage(systemName: "folder.badge.plus")
    ) { [weak self] _ in
      guard let self else { return }
      presentFolderPicker(
        title: "Also Show in Folder",
        includesRootDestination: false
      ) { [weak self] destinationFolderId in
        guard let destinationFolderId else { return }
        self?.folderStore.addPlaylists([playlist.id], to: destinationFolderId)
      }
    })

    if let currentFolderId = parentFolderId {
      actions.append(UIAction(
        title: "Remove from This Folder",
        image: UIImage(systemName: "folder.badge.minus"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.folderStore.removePlaylists([playlist.id], from: currentFolderId)
      })
    }

    actions.append(UIAction(
      title: "Delete Playlist",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { [weak self] _ in
      self?.confirmDeletePlaylist(playlist)
    })

    return actions
  }
}
