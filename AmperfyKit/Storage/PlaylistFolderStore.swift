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

  public func deleteFolder(id: UUID) {
    folders = Self.removingFolder(id: id, from: folders)
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

  private static func removingFolder(id: UUID, from folders: [PlaylistFolder]) -> [PlaylistFolder] {
    folders.compactMap { folder in
      if folder.id == id { return nil }
      var mutableFolder = folder
      mutableFolder.subfolders = removingFolder(id: id, from: mutableFolder.subfolders)
      return mutableFolder
    }
  }
}
