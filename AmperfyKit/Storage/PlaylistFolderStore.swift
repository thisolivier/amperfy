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

import CoreData
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

  // MARK: - Dependencies (set after init via configure())

  private var managedObjectContext: NSManagedObjectContext?
  private var navidromeApi: NavidromeServerApi?
  private var accountMO: AccountMO?

  /// Configure with CoreData context and API client.
  /// Called once during app startup after storage is initialized.
  public func configure(
    context: NSManagedObjectContext,
    navidromeApi: NavidromeServerApi?,
    account: AccountMO?
  ) {
    self.managedObjectContext = context
    self.navidromeApi = navidromeApi
    self.accountMO = account
  }

  /// Whether the store has been configured with CoreData.
  private var isConfigured: Bool {
    managedObjectContext != nil
  }

  // MARK: - Legacy UserDefaults support

  private let defaultsKey = "amperfy.fork.playlistFolders"
  private let defaults: UserDefaults
  private var _legacyFolders: [PlaylistFolder]?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Folders property

  public var folders: [PlaylistFolder] {
    get {
      guard let context = managedObjectContext else { return loadFromUserDefaults() }
      return buildFolderTree(from: context)
    }
    set {
      // Setter exists for API compatibility but should not be used directly
      // when CoreData is configured. Mutations go through createFolder/deleteFolder/etc.
      guard !isConfigured else {
        notifyChange()
        return
      }
      // Legacy path: persist to UserDefaults
      _legacyFolders = newValue
      legacyPersist()
    }
  }

  // MARK: - Computed

  /// All playlist IDs that appear in at least one folder at any depth.
  public var allFiledPlaylistIds: Set<String> {
    guard let context = managedObjectContext else {
      return folders.reduce(into: Set<String>()) { result, folder in
        result.formUnion(folder.allPlaylistIdsRecursive)
      }
    }
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    guard let folderMOs = try? context.fetch(fetchRequest) else { return [] }
    var result = Set<String>()
    for folderMO in folderMOs {
      if let playlists = folderMO.playlists as? Set<PlaylistMO> {
        for playlistMO in playlists {
          result.insert(playlistMO.id)
        }
      }
    }
    return result
  }

  // MARK: - CRUD: Folders

  @discardableResult
  public func createFolder(name: String, parent: UUID?) -> PlaylistFolder {
    guard let context = managedObjectContext else {
      return legacyCreateFolder(name: name, parent: parent)
    }

    let newFolder = PlaylistFolder(name: name)

    // Resolve parent server ID from UUID if provided
    var parentServerId: String?
    if let parentUUID = parent,
      let parentMO = findFolderMO(by: parentUUID, in: context)
    {
      parentServerId = parentMO.id
    }

    // Create in CoreData immediately (optimistic)
    let folderMO = PlaylistFolderMO(context: context)
    folderMO.id = newFolder.id.uuidString
    folderMO.name = name
    folderMO.parentId = parentServerId
    folderMO.account = accountMO
    try? context.save()

    // Fire-and-forget server creation
    if let api = navidromeApi {
      nonisolated(unsafe) let unsafeFolderMO = folderMO
      nonisolated(unsafe) let unsafeContext = context
      Task {
        do {
          let serverResponse = try await api.createFolder(
            name: name, parentId: parentServerId)
          // Update the local MO with server-assigned ID
          await MainActor.run {
            unsafeFolderMO.id = serverResponse.id
            if let serverParentId = serverResponse.parentId {
              unsafeFolderMO.parentId = serverParentId
            }
            try? unsafeContext.save()
          }
        } catch {
          // Server creation failed — the optimistic local entry remains.
          // It will be reconciled on next sync.
        }
      }
    }

    notifyChange()
    return newFolder
  }

  public func renameFolder(id: UUID, to name: String) {
    guard let context = managedObjectContext else {
      legacyRenameFolder(id: id, to: name)
      return
    }

    guard let folderMO = findFolderMO(by: id, in: context) else { return }
    let serverId = folderMO.id
    folderMO.name = name
    try? context.save()

    if let api = navidromeApi {
      Task {
        try? await api.updateFolder(id: serverId, name: name, parentId: nil)
      }
    }

    notifyChange()
  }

  /// Deletes the folder with the given id, lifting its direct `playlistIds` and
  /// `subfolders` up one level into the containing array (root if the folder
  /// was at root). Grandchildren remain inside their direct parent — the pop is
  /// one level only. Playlists themselves are never deleted.
  public func deleteFolder(id: UUID) {
    guard let context = managedObjectContext else {
      legacyDeleteFolder(id: id)
      return
    }

    guard let folderMO = findFolderMO(by: id, in: context) else { return }
    let serverId = folderMO.id
    let parentId = folderMO.parentId

    // Promote child folders: move their parentId to this folder's parentId
    let childFolders = fetchChildFolders(of: serverId, in: context)
    for childMO in childFolders {
      childMO.parentId = parentId
    }

    // Promote playlists to parent folder if one exists
    if let parentId = parentId,
      let parentMO = fetchFolderMO(byServerId: parentId, in: context),
      let playlists = folderMO.playlists as? Set<PlaylistMO>
    {
      for playlistMO in playlists {
        parentMO.addToPlaylists(playlistMO)
      }
    }

    // Remove the folder (remaining playlists become unfiled)
    context.delete(folderMO)
    try? context.save()

    if let api = navidromeApi {
      Task {
        try? await api.deleteFolder(id: serverId)
      }
    }

    notifyChange()
  }

  // MARK: - Membership

  public func addPlaylists(_ playlistIds: [String], to folderId: UUID) {
    guard let context = managedObjectContext else {
      legacyAddPlaylists(playlistIds, to: folderId)
      return
    }

    guard let folderMO = findFolderMO(by: folderId, in: context) else { return }
    let serverId = folderMO.id

    for playlistId in playlistIds {
      if let playlistMO = fetchPlaylistMO(by: playlistId, in: context) {
        folderMO.addToPlaylists(playlistMO)
      }
    }
    try? context.save()

    if let api = navidromeApi {
      Task {
        for playlistId in playlistIds {
          try? await api.addPlaylistToFolder(folderId: serverId, playlistId: playlistId)
        }
      }
    }

    notifyChange()
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: UUID) {
    guard let context = managedObjectContext else {
      legacyRemovePlaylists(playlistIds, from: folderId)
      return
    }

    guard let folderMO = findFolderMO(by: folderId, in: context) else { return }
    let serverId = folderMO.id

    for playlistId in playlistIds {
      if let playlistMO = fetchPlaylistMO(by: playlistId, in: context) {
        folderMO.removeFromPlaylists(playlistMO)
      }
    }
    try? context.save()

    if let api = navidromeApi {
      Task {
        for playlistId in playlistIds {
          try? await api.removePlaylistFromFolder(folderId: serverId, playlistId: playlistId)
        }
      }
    }

    notifyChange()
  }

  public func movePlaylist(
    _ playlistId: String, from sourceFolderId: UUID, to destFolderId: UUID
  ) {
    removePlaylists([playlistId], from: sourceFolderId)
    addPlaylists([playlistId], to: destFolderId)
  }

  // MARK: - Query

  public func folder(byId id: UUID) -> PlaylistFolder? {
    Self.findFolder(id: id, in: folders)
  }

  // MARK: - Sync (called during library sync)

  /// Sync folders from server to CoreData. Called during library sync flow.
  public func syncFromServer() async throws {
    guard let api = navidromeApi, let context = managedObjectContext else { return }

    let serverFolders = try await api.listFolders()

    await MainActor.run {
      let existingFolders = (try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []
      let existingById = Dictionary(
        uniqueKeysWithValues: existingFolders.map { ($0.id, $0) })
      var serverIds = Set<String>()

      for serverFolder in serverFolders {
        serverIds.insert(serverFolder.id)
        if let existing = existingById[serverFolder.id] {
          // Update
          existing.name = serverFolder.name
          existing.parentId = serverFolder.parentId
        } else {
          // Insert
          let newMO = PlaylistFolderMO(context: context)
          newMO.id = serverFolder.id
          newMO.name = serverFolder.name
          newMO.parentId = serverFolder.parentId
          newMO.account = self.accountMO
        }
      }

      // Delete folders not on server
      for existing in existingFolders {
        if !serverIds.contains(existing.id) {
          context.delete(existing)
        }
      }

      try? context.save()
    }

    notifyChange()
  }

  /// Sync folder memberships from playlist folderIds field.
  /// Call after syncing playlists, passing the folderIds from each playlist's API response.
  public func syncMemberships(playlistId: String, folderIds: [String]) {
    guard let context = managedObjectContext else { return }
    guard let playlistMO = fetchPlaylistMO(by: playlistId, in: context) else { return }

    // Remove all existing folder relationships
    if let existingFolders = playlistMO.folders as? Set<PlaylistFolderMO> {
      for folderMO in existingFolders {
        folderMO.removeFromPlaylists(playlistMO)
      }
    }

    // Add to the specified folders
    for folderId in folderIds {
      if let folderMO = fetchFolderMO(byServerId: folderId, in: context) {
        folderMO.addToPlaylists(playlistMO)
      }
    }

    try? context.save()
  }

  // MARK: - CoreData Helpers

  private func buildFolderTree(from context: NSManagedObjectContext) -> [PlaylistFolder] {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    guard let allFolders = try? context.fetch(fetchRequest) else { return [] }

    // Build tree: root folders have nil/empty parentId
    let rootFolders = allFolders.filter {
      $0.parentId == nil || $0.parentId?.isEmpty == true
    }

    return rootFolders.map { buildPlaylistFolder(from: $0, allFolders: allFolders) }
  }

  private func buildPlaylistFolder(
    from folderMO: PlaylistFolderMO,
    allFolders: [PlaylistFolderMO]
  ) -> PlaylistFolder {
    let children = allFolders.filter { $0.parentId == folderMO.id }
    let playlistIds = (folderMO.playlists as? Set<PlaylistMO>)?.map { $0.id } ?? []

    return PlaylistFolder(
      id: UUID(uuidString: folderMO.id) ?? UUID(),
      name: folderMO.name,
      playlistIds: playlistIds.sorted(),
      subfolders: children.map { buildPlaylistFolder(from: $0, allFolders: allFolders) }
    )
  }

  private func findFolderMO(by uuid: UUID, in context: NSManagedObjectContext)
    -> PlaylistFolderMO?
  {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", uuid.uuidString)
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  private func fetchFolderMO(byServerId serverId: String, in context: NSManagedObjectContext)
    -> PlaylistFolderMO?
  {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", serverId)
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  private func fetchChildFolders(of parentId: String, in context: NSManagedObjectContext)
    -> [PlaylistFolderMO]
  {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "parentId == %@", parentId)
    return (try? context.fetch(fetchRequest)) ?? []
  }

  private func fetchPlaylistMO(by playlistId: String, in context: NSManagedObjectContext)
    -> PlaylistMO?
  {
    let fetchRequest = PlaylistMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", playlistId)
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  private func notifyChange() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  // MARK: - Static Helpers

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
    mutation: (inout PlaylistFolder) -> Void
  )
    -> [PlaylistFolder]
  {
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
    -> [PlaylistFolder]
  {
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
    id: UUID,
    into parent: PlaylistFolder
  )
    -> PlaylistFolder
  {
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

  // MARK: - Legacy UserDefaults Fallback

  private func loadFromUserDefaults() -> [PlaylistFolder] {
    if let cached = _legacyFolders { return cached }
    guard let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([PlaylistFolder].self, from: data)
    else { return [] }
    _legacyFolders = decoded
    return decoded
  }

  private func legacyPersist() {
    if let data = try? JSONEncoder().encode(_legacyFolders ?? []) {
      defaults.set(data, forKey: defaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func legacyMutateFolder(id: UUID, mutation: (inout PlaylistFolder) -> Void) {
    var currentFolders = loadFromUserDefaults()
    currentFolders = Self.applyingMutation(id: id, to: currentFolders, mutation: mutation)
    _legacyFolders = currentFolders
    legacyPersist()
  }

  @discardableResult
  private func legacyCreateFolder(name: String, parent: UUID?) -> PlaylistFolder {
    let newFolder = PlaylistFolder(name: name)
    if let parentId = parent {
      legacyMutateFolder(id: parentId) { parentFolder in
        parentFolder.subfolders.append(newFolder)
      }
    } else {
      var currentFolders = loadFromUserDefaults()
      currentFolders.append(newFolder)
      _legacyFolders = currentFolders
      legacyPersist()
    }
    return newFolder
  }

  private func legacyRenameFolder(id: UUID, to name: String) {
    legacyMutateFolder(id: id) { folder in
      folder.name = name
    }
  }

  private func legacyDeleteFolder(id: UUID) {
    let currentFolders = loadFromUserDefaults()
    _legacyFolders = Self.flatteningFolder(id: id, from: currentFolders)
    legacyPersist()
  }

  private func legacyAddPlaylists(_ playlistIds: [String], to folderId: UUID) {
    legacyMutateFolder(id: folderId) { folder in
      for playlistId in playlistIds where !folder.playlistIds.contains(playlistId) {
        folder.playlistIds.append(playlistId)
      }
    }
  }

  private func legacyRemovePlaylists(_ playlistIds: [String], from folderId: UUID) {
    legacyMutateFolder(id: folderId) { folder in
      folder.playlistIds.removeAll { playlistIds.contains($0) }
    }
  }
}
