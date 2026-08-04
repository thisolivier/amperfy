//
//  PlaylistFolderStore+Legacy.swift
//  AmperfyKit
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

import Foundation

/// The pre-Core-Data folder store, kept as the fallback used before storage is
/// configured (and by the tests that pin its tree-splicing behaviour).
///
/// It has no placements and no sortOrder: folders here are a plain nested value
/// tree persisted to `UserDefaults`, ordered by array position.
extension PlaylistFolderStore {
  // MARK: - Persistence

  func loadFromUserDefaults() -> [PlaylistFolder] {
    if let cachedFolders = legacyFoldersCache { return cachedFolders }
    guard let encodedFolders = defaults.data(forKey: defaultsKey),
          let decodedFolders = try? JSONDecoder().decode(
            [PlaylistFolder].self, from: encodedFolders
          )
    else { return [] }
    legacyFoldersCache = decodedFolders
    return decodedFolders
  }

  func legacyPersist() {
    if let encodedFolders = try? JSONEncoder().encode(legacyFoldersCache ?? []) {
      defaults.set(encodedFolders, forKey: defaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func legacyMutateFolder(id: String, mutation: (inout PlaylistFolder) -> ()) {
    var currentFolders = loadFromUserDefaults()
    currentFolders = Self.applyingMutation(id: id, to: currentFolders, mutation: mutation)
    legacyFoldersCache = currentFolders
    legacyPersist()
  }

  // MARK: - Mutations

  @discardableResult
  func legacyCreateFolder(name: String, parent: String?) -> PlaylistFolder {
    let newFolder = PlaylistFolder(name: name)
    if let parentId = parent {
      legacyMutateFolder(id: parentId) { parentFolder in
        parentFolder.subfolders.append(newFolder)
      }
    } else {
      var currentFolders = loadFromUserDefaults()
      currentFolders.append(newFolder)
      legacyFoldersCache = currentFolders
      legacyPersist()
    }
    return newFolder
  }

  func legacyRenameFolder(id: String, to name: String) {
    legacyMutateFolder(id: id) { folder in
      folder.name = name
    }
  }

  func legacyDeleteFolder(id: String) {
    let currentFolders = loadFromUserDefaults()
    legacyFoldersCache = Self.flatteningFolder(id: id, from: currentFolders)
    legacyPersist()
  }

  func legacyAddPlaylists(_ playlistIds: [String], to folderId: String) {
    legacyMutateFolder(id: folderId) { folder in
      for playlistId in playlistIds where !folder.playlistIds.contains(playlistId) {
        folder.playlistIds.append(playlistId)
      }
    }
  }

  func legacyRemovePlaylists(_ playlistIds: [String], from folderId: String) {
    legacyMutateFolder(id: folderId) { folder in
      folder.playlistIds.removeAll { playlistIds.contains($0) }
    }
  }

  // MARK: - Tree splicing

  static func applyingMutation(
    id: String,
    to folders: [PlaylistFolder],
    mutation: (inout PlaylistFolder) -> ()
  )
    -> [PlaylistFolder] {
    folders.map { folder in
      var mutableFolder = folder
      if mutableFolder.id == id {
        mutation(&mutableFolder)
      } else {
        mutableFolder.subfolders = applyingMutation(
          id: id,
          to: mutableFolder.subfolders,
          mutation: mutation
        )
      }
      return mutableFolder
    }
  }

  /// Tree-walk splice: when a folder with the given id is found in `folders`,
  /// replace it in-place with its direct `subfolders` (its direct `playlistIds`
  /// are attached to the containing folder by ``spliceDirectChild(id:into:)``).
  static func flatteningFolder(
    id: String,
    from folders: [PlaylistFolder]
  )
    -> [PlaylistFolder] {
    var result = [PlaylistFolder]()
    result.reserveCapacity(folders.count)
    for folder in folders {
      if folder.id == id {
        result.append(contentsOf: folder.subfolders)
      } else {
        var mutableFolder = folder
        if folder.subfolders.contains(where: { $0.id == id }) {
          mutableFolder = spliceDirectChild(id: id, into: mutableFolder)
        } else {
          mutableFolder.subfolders = flatteningFolder(id: id, from: mutableFolder.subfolders)
        }
        result.append(mutableFolder)
      }
    }
    return result
  }

  /// Splice the direct-child folder `id` out of `parent`, lifting its
  /// `playlistIds` into `parent.playlistIds` and its `subfolders` into
  /// `parent.subfolders` at the deletion site.
  private static func spliceDirectChild(
    id: String,
    into parent: PlaylistFolder
  )
    -> PlaylistFolder {
    guard let index = parent.subfolders.firstIndex(where: { $0.id == id }) else {
      return parent
    }
    var mutableParent = parent
    let target = mutableParent.subfolders[index]
    mutableParent.subfolders.remove(at: index)
    mutableParent.subfolders.insert(contentsOf: target.subfolders, at: index)
    for playlistId in target.playlistIds
      where !mutableParent.playlistIds.contains(playlistId) {
      mutableParent.playlistIds.append(playlistId)
    }
    return mutableParent
  }
}
