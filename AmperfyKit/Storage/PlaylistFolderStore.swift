//
//  PlaylistFolderStore.swift
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

// MARK: - PlaylistFolder

public struct PlaylistFolder: Codable, Identifiable, Equatable {
  public let id: UUID
  public var name: String
  public var playlistIds: [String]
  public var subfolders: [PlaylistFolder]

  public init(
    id: UUID = UUID(),
    name: String,
    playlistIds: [String] = [],
    subfolders: [PlaylistFolder] = []
  ) {
    self.id = id
    self.name = name
    self.playlistIds = playlistIds
    self.subfolders = subfolders
  }

  /// All playlist IDs contained in this folder and all subfolders recursively.
  public var allPlaylistIdsRecursive: Set<String> {
    var result = Set(playlistIds)
    for subfolder in subfolders {
      result.formUnion(subfolder.allPlaylistIdsRecursive)
    }
    return result
  }
}

// MARK: - PlaylistFolderStore

public final class PlaylistFolderStore: @unchecked Sendable {
  public static let shared = PlaylistFolderStore()

  public static let didChangeNotification = Notification.Name(
    "amperfy.fork.playlistFolders.didChange"
  )

  private let defaultsKey = "amperfy.fork.playlistFolders"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self._folders = Self.loadFolders(from: defaults, key: defaultsKey)
  }

  // MARK: - Folders property

  private var _folders: [PlaylistFolder]

  public var folders: [PlaylistFolder] {
    get { _folders }
    set {
      _folders = newValue
      persist()
    }
  }

  // MARK: - Computed

  /// All playlist IDs that appear in at least one folder at any depth.
  public var allFiledPlaylistIds: Set<String> {
    var result = Set<String>()
    for folder in folders {
      result.formUnion(folder.allPlaylistIdsRecursive)
    }
    return result
  }

  // MARK: - CRUD: Folders

  @discardableResult
  public func createFolder(name: String, parent: UUID?) -> PlaylistFolder {
    let newFolder = PlaylistFolder(name: name)
    if let parentId = parent {
      mutateFolder(id: parentId) { parentFolder in
        parentFolder.subfolders.append(newFolder)
      }
    } else {
      folders.append(newFolder)
    }
    return newFolder
  }

  public func renameFolder(id: UUID, to name: String) {
    mutateFolder(id: id) { folder in
      folder.name = name
    }
  }

  /// Deletes the folder with the given id, lifting its direct `playlistIds` and
  /// `subfolders` up one level into the containing array (root if the folder
  /// was at root). Grandchildren remain inside their direct parent — the pop is
  /// one level only. Playlists themselves are never deleted.
  public func deleteFolder(id: UUID) {
    folders = Self.flatteningFolder(id: id, from: folders)
    persist()
  }

  // MARK: - Membership

  public func addPlaylists(_ playlistIds: [String], to folderId: UUID) {
    mutateFolder(id: folderId) { folder in
      for playlistId in playlistIds where !folder.playlistIds.contains(playlistId) {
        folder.playlistIds.append(playlistId)
      }
    }
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: UUID) {
    mutateFolder(id: folderId) { folder in
      folder.playlistIds.removeAll { playlistIds.contains($0) }
    }
  }

  public func movePlaylist(_ playlistId: String, from sourceFolderId: UUID, to destFolderId: UUID) {
    removePlaylists([playlistId], from: sourceFolderId)
    addPlaylists([playlistId], to: destFolderId)
  }

  // MARK: - Query

  public func folder(byId id: UUID) -> PlaylistFolder? {
    Self.findFolder(id: id, in: folders)
  }

  // MARK: - Private helpers

  private func persist() {
    if let data = try? JSONEncoder().encode(_folders) {
      defaults.set(data, forKey: defaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func mutateFolder(id: UUID, mutation: (inout PlaylistFolder) -> ()) {
    folders = Self.applyingMutation(id: id, to: folders, mutation: mutation)
    persist()
  }

  private static func loadFolders(from defaults: UserDefaults, key: String) -> [PlaylistFolder] {
    guard let data = defaults.data(forKey: key),
          let decoded = try? JSONDecoder().decode([PlaylistFolder].self, from: data)
    else { return [] }
    return decoded
  }

  private static func findFolder(id: UUID, in folders: [PlaylistFolder]) -> PlaylistFolder? {
    for folder in folders {
      if folder.id == id { return folder }
      if let found = findFolder(id: id, in: folder.subfolders) { return found }
    }
    return nil
  }

  private static func applyingMutation(
    id: UUID,
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
  /// are attached to the containing folder by the caller via a companion
  /// walk). Since `playlistIds` live on the *parent* folder, the top-level
  /// splice uses the overload below that returns both the new subfolder list
  /// and the playlist IDs to lift.
  private static func flatteningFolder(
    id: UUID,
    from folders: [PlaylistFolder]
  )
    -> [PlaylistFolder] {
    var result = [PlaylistFolder]()
    result.reserveCapacity(folders.count)
    for folder in folders {
      if folder.id == id {
        // Splice: replace this folder with its direct children at this level.
        // The playlistIds that were inside `folder` also lift to this level —
        // but at the root there is no containing folder, so they become
        // unfiled relative to the deleted folder and will be picked up by
        // `fetchUnfiledPlaylists`. That is exactly the desired "pop up one
        // level" semantic for root-level deletes.
        result.append(contentsOf: folder.subfolders)
      } else {
        var mutableFolder = folder
        if folder.subfolders.contains(where: { $0.id == id }) {
          // The deletion target is a direct child of this folder — splice its
          // children into this folder's direct arrays.
          mutableFolder = spliceDirectChild(id: id, into: mutableFolder)
        } else {
          // Target is deeper or absent; recurse.
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
    id: UUID,
    into parent: PlaylistFolder
  )
    -> PlaylistFolder {
    guard let index = parent.subfolders.firstIndex(where: { $0.id == id }) else {
      return parent
    }
    var mutableParent = parent
    let target = mutableParent.subfolders[index]
    mutableParent.subfolders.remove(at: index)
    // Lift the deleted folder's direct subfolders into the parent at the
    // deletion index (preserves local ordering where possible).
    mutableParent.subfolders.insert(contentsOf: target.subfolders, at: index)
    // Lift the deleted folder's direct playlistIds, deduping against what the
    // parent already has.
    for playlistId in target.playlistIds
      where !mutableParent.playlistIds.contains(playlistId) {
      mutableParent.playlistIds.append(playlistId)
    }
    return mutableParent
  }
}
