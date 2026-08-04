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
import os.log

// MARK: - PlaylistFolderOrganizationFetcher

/// Fetches the server's v2 playlist-folder organization envelope.
///
/// Injectable so the capability probe can be exercised without a live
/// Navidrome instance.
public typealias PlaylistFolderOrganizationFetcher =
  @Sendable () async throws -> NavidromeFolderOrganizationResponse

// MARK: - PlaylistFolder

public struct PlaylistFolder: Codable, Identifiable, Equatable {
  public let id: UUID
  public var name: String
  /// Playlist ids placed directly in this folder, already in sibling order.
  public var playlistIds: [String]
  /// Direct subfolders, already in sibling order.
  public var subfolders: [PlaylistFolder]
  /// This folder's own position among its siblings. `nil` means unordered,
  /// which sorts after every ordered sibling.
  public var sortOrder: Int?

  public init(
    id: UUID = UUID(),
    name: String,
    playlistIds: [String] = [],
    subfolders: [PlaylistFolder] = [],
    sortOrder: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.playlistIds = playlistIds
    self.subfolders = subfolders
    self.sortOrder = sortOrder
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

/// Owns the device's playlist-folder organization.
///
/// ## Placements, not memberships
/// Organization is stored as *placement edges* — one row per (playlist, folder)
/// pair, each carrying its own `sortOrder` — mirroring the v2 server contract.
/// A playlist may hold several placements at once; a playlist with none is
/// implicitly at the root, unordered.
///
/// ## Ordering
/// Sibling folders and sibling playlists share one ordering space per parent.
/// See ``PlaylistFolderOrdering`` for the comparator and the gap-numbering
/// scheme used when assigning new `sortOrder` values.
///
/// ## Safety
/// Server-driven reconciliation is gated by ``PlaylistFolderSyncCapability``
/// (see `PlaylistFolderStore+Sync.swift`), and every successful local mutation
/// writes a JSON snapshot through ``PlaylistFolderTreeExporter``.
public final class PlaylistFolderStore: @unchecked Sendable {
  public static let shared = PlaylistFolderStore()

  public static let didChangeNotification = Notification.Name(
    "amperfy.fork.playlistFolders.didChange"
  )

  // MARK: - Dependencies (set after init via configure())

  var managedObjectContext: NSManagedObjectContext?
  var navidromeApi: NavidromeServerApi?
  var accountMO: AccountMO?
  var folderOrganizationFetcher: PlaylistFolderOrganizationFetcher?
  var treeExporter: PlaylistFolderTreeExporter

  let logger = Logger(
    subsystem: "dev.thisolivier.amperfy",
    category: "PlaylistFolderSync"
  )
  /// Guards the "server has no folder API" warning so a per-sync condition does
  /// not spam the log on every library refresh.
  var hasLoggedServerLacksFolderApi = false

  /// Configure with CoreData context and API client.
  /// Called once during app startup after storage is initialized.
  public func configure(
    context: NSManagedObjectContext,
    navidromeApi: NavidromeServerApi?,
    account: AccountMO?
  ) {
    managedObjectContext = context
    self.navidromeApi = navidromeApi
    accountMO = account
    if let api = navidromeApi {
      let fetcher: PlaylistFolderOrganizationFetcher = {
        try await api.fetchFolderOrganization()
      }
      folderOrganizationFetcher = fetcher
    } else {
      folderOrganizationFetcher = nil
    }
    hasLoggedServerLacksFolderApi = false
    backfillPlacementsFromLegacyMembershipsIfNeeded(in: context)
  }

  /// Test seam: configure the destructive sync path without a live Navidrome
  /// client, supplying the capability probe directly.
  func configureForTesting(
    context: NSManagedObjectContext,
    account: AccountMO?,
    organizationFetcher: PlaylistFolderOrganizationFetcher? = nil,
    treeExporter: PlaylistFolderTreeExporter? = nil
  ) {
    managedObjectContext = context
    navidromeApi = nil
    accountMO = account
    folderOrganizationFetcher = organizationFetcher
    hasLoggedServerLacksFolderApi = false
    if let treeExporter {
      self.treeExporter = treeExporter
    }
  }

  /// Whether the store has been configured with CoreData.
  var isConfigured: Bool {
    managedObjectContext != nil
  }

  // MARK: - Legacy UserDefaults support

  let defaultsKey = "amperfy.fork.playlistFolders"
  let defaults: UserDefaults
  var legacyFoldersCache: [PlaylistFolder]?

  public init(
    defaults: UserDefaults = .standard,
    treeExporter: PlaylistFolderTreeExporter = PlaylistFolderTreeExporter()
  ) {
    self.defaults = defaults
    self.treeExporter = treeExporter
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
      legacyFoldersCache = newValue
      legacyPersist()
    }
  }

  // MARK: - Computed

  /// All playlist IDs placed in at least one real folder at any depth.
  ///
  /// An explicit *root* placement does not count as filed — it orders a playlist
  /// within the root list rather than moving it out of it.
  public var allFiledPlaylistIds: Set<String> {
    guard let context = managedObjectContext else {
      return folders.reduce(into: Set<String>()) { result, folder in
        result.formUnion(folder.allPlaylistIdsRecursive)
      }
    }
    var result = Set<String>()
    for placementMO in fetchPlacements(in: context) {
      guard !PlaylistFolderRootId.isRoot(placementMO.folderId),
            let playlistId = placementMO.playlist?.id else { continue }
      result.insert(playlistId)
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
       let parentMO = findFolderMO(by: parentUUID, in: context) {
      parentServerId = parentMO.id
    }

    // A new folder lands after everything already in its parent.
    let appendSortOrder = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: PlaylistFolderRootId.normalized(parentServerId), in: context)
    )

    // Create in CoreData immediately (optimistic)
    let folderMO = PlaylistFolderMO(context: context)
    folderMO.id = newFolder.id.uuidString
    folderMO.name = name
    folderMO.parentId = parentServerId
    folderMO.sortOrderValue = appendSortOrder
    folderMO.account = accountMO
    try? context.save()

    // Fire-and-forget server creation
    if let api = navidromeApi {
      nonisolated(unsafe) let unsafeFolderMO = folderMO
      nonisolated(unsafe) let unsafeContext = context
      Task {
        do {
          let serverResponse = try await api.createFolder(
            name: name, parentId: parentServerId, sortOrder: appendSortOrder
          )
          // Adopt the server-assigned id, carrying any placements or child
          // folders made against the optimistic local id across to it.
          await MainActor.run {
            let optimisticFolderId = unsafeFolderMO.id
            unsafeFolderMO.id = serverResponse.id
            unsafeFolderMO.parentId = serverResponse.normalizedParentId
            if let serverSortOrder = serverResponse.sortOrder {
              unsafeFolderMO.sortOrderValue = serverSortOrder
            }
            self.repointFolderReferences(
              from: optimisticFolderId,
              to: serverResponse.id,
              in: unsafeContext
            )
            try? unsafeContext.save()
            self.exportCurrentTree()
          }
        } catch {
          // Server creation failed — the optimistic local entry remains.
          // It will be reconciled on next sync.
        }
      }
    }

    notifyChange()
    exportCurrentTree()
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
        try? await api.updateFolder(id: serverId, name: name)
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  /// Move a folder into a different parent, appending it after that parent's
  /// existing children.
  ///
  /// The server answers 400 if the move would create a cycle; the same check
  /// runs locally first so an illegal move is refused outright rather than
  /// applied optimistically and then bounced.
  public func moveFolder(id: UUID, toParent newParentFolderId: UUID?) {
    guard let context = managedObjectContext else { return }
    guard let folderMO = findFolderMO(by: id, in: context) else { return }

    var newParentServerId: String?
    if let newParentFolderId {
      guard let newParentMO = findFolderMO(by: newParentFolderId, in: context) else { return }
      newParentServerId = newParentMO.id
    }

    let normalizedNewParentId = PlaylistFolderRootId.normalized(newParentServerId)
    guard !wouldCreateCycle(
      movingFolderId: folderMO.id,
      intoParentId: normalizedNewParentId,
      in: context
    ) else {
      logger.warning("Refusing playlist folder move: it would create a cycle")
      return
    }

    let serverId = folderMO.id
    let appendSortOrder = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: normalizedNewParentId, in: context)
    )
    folderMO.parentId = newParentServerId
    folderMO.sortOrderValue = appendSortOrder
    try? context.save()

    if let api = navidromeApi {
      let serverParentId = normalizedNewParentId.isEmpty
        ? PlaylistFolderRootId.literal : normalizedNewParentId
      Task {
        try? await api.updateFolder(
          id: serverId,
          parentId: serverParentId,
          sortOrder: .set(appendSortOrder)
        )
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  /// Deletes the folder with the given id, lifting its direct playlists and
  /// subfolders up one level into the containing folder (root if the folder was
  /// at root). Grandchildren remain inside their direct parent — the pop is one
  /// level only. Playlists themselves are never deleted.
  ///
  /// The server's own delete re-parents child *folders* but merely drops the
  /// deleted folder's placements, which would scatter its playlists to the root.
  /// To keep this fork's friendlier behaviour, the lifted placements are written
  /// to the server explicitly *before* the folder is deleted, so server and
  /// device agree once the dust settles.
  public func deleteFolder(id: UUID) {
    guard let context = managedObjectContext else {
      legacyDeleteFolder(id: id)
      return
    }

    guard let folderMO = findFolderMO(by: id, in: context) else { return }
    let serverId = folderMO.id
    let parentId = folderMO.parentId
    let normalizedParentId = PlaylistFolderRootId.normalized(parentId)

    // Promote child folders: move their parentId to this folder's parentId
    for childFolderMO in fetchChildFolders(of: serverId, in: context) {
      childFolderMO.parentId = parentId
    }

    // Promote the folder's playlists into the parent's ordering space.
    var promotedPlaylistIds = [String]()
    var nextSortOrder = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: normalizedParentId, in: context)
    )
    for placementMO in fetchPlacements(folderId: serverId, in: context) {
      guard let playlistMO = placementMO.playlist else {
        context.delete(placementMO)
        continue
      }
      if fetchPlacement(
        playlistId: playlistMO.id, folderId: normalizedParentId, in: context
      ) != nil {
        // Already placed in the parent — the lifted edge would be a duplicate.
        context.delete(placementMO)
        continue
      }
      promotedPlaylistIds.append(playlistMO.id)
      // Re-point the existing edge at the parent rather than deleting and
      // re-creating it, so the playlist is never momentarily unfiled.
      placementMO.folderId = normalizedParentId
      placementMO.sortOrderValue = nextSortOrder
      nextSortOrder += PlaylistFolderOrdering.sortOrderGap
    }

    context.delete(folderMO)
    try? context.save()

    if let api = navidromeApi {
      let playlistIdsToPromote = promotedPlaylistIds
      let promotionTargetId = normalizedParentId.isEmpty
        ? PlaylistFolderRootId.literal : normalizedParentId
      Task {
        // Re-file first: once the folder is gone the server has nothing left to
        // re-file from.
        for playlistId in playlistIdsToPromote {
          try? await api.setPlaylistPlacement(
            folderId: promotionTargetId, playlistId: playlistId
          )
        }
        try? await api.deleteFolder(id: serverId)
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  // MARK: - Placements

  public func addPlaylists(_ playlistIds: [String], to folderId: UUID) {
    // A not-yet-synced playlist has an empty server id until its create request
    // round-trips. Filing by "" would both pollute the filed set and file
    // nothing on the server (so the membership is lost on the next folder
    // reconciliation). Callers must file only after the id is assigned; drop
    // empty ids defensively so a mistimed call can never corrupt membership.
    let validPlaylistIds = playlistIds.filter { !$0.isEmpty }
    guard !validPlaylistIds.isEmpty else { return }

    guard let context = managedObjectContext else {
      legacyAddPlaylists(validPlaylistIds, to: folderId)
      return
    }

    guard let folderMO = findFolderMO(by: folderId, in: context) else { return }
    let serverId = folderMO.id

    var appendedSortOrders = [(playlistId: String, sortOrder: Int)]()
    var nextSortOrder = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: serverId, in: context)
    )
    for playlistId in validPlaylistIds {
      guard let playlistMO = fetchPlaylistMO(by: playlistId, in: context) else { continue }
      let placementMO = fetchPlacement(
        playlistId: playlistId, folderId: serverId, in: context
      ) ?? makePlacementMO(playlist: playlistMO, folderId: serverId, in: context)
      placementMO.sortOrderValue = nextSortOrder
      appendedSortOrders.append((playlistId: playlistId, sortOrder: nextSortOrder))
      nextSortOrder += PlaylistFolderOrdering.sortOrderGap
    }
    try? context.save()

    if let api = navidromeApi {
      let placementsToWrite = appendedSortOrders
      Task {
        for placement in placementsToWrite {
          try? await api.setPlaylistPlacement(
            folderId: serverId,
            playlistId: placement.playlistId,
            sortOrder: placement.sortOrder
          )
        }
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: UUID) {
    guard let context = managedObjectContext else {
      legacyRemovePlaylists(playlistIds, from: folderId)
      return
    }

    guard let folderMO = findFolderMO(by: folderId, in: context) else { return }
    let serverId = folderMO.id

    for playlistId in playlistIds {
      guard let placementMO = fetchPlacement(
        playlistId: playlistId, folderId: serverId, in: context
      ) else { continue }
      context.delete(placementMO)
    }
    try? context.save()

    if let api = navidromeApi {
      Task {
        for playlistId in playlistIds {
          try? await api.removePlaylistPlacement(folderId: serverId, playlistId: playlistId)
        }
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  /// Move a playlist between folders.
  ///
  /// Uses the contract's replace-all endpoint rather than a remove/add pair: a
  /// playlist may legitimately sit in several folders, so the server is told the
  /// complete resulting placement set in one call and no intermediate state is
  /// ever visible to another client.
  public func movePlaylist(
    _ playlistId: String, from sourceFolderId: UUID, to destFolderId: UUID
  ) {
    guard let context = managedObjectContext else {
      legacyRemovePlaylists([playlistId], from: sourceFolderId)
      legacyAddPlaylists([playlistId], to: destFolderId)
      return
    }

    guard let sourceFolderMO = findFolderMO(by: sourceFolderId, in: context),
          let destinationFolderMO = findFolderMO(by: destFolderId, in: context),
          let playlistMO = fetchPlaylistMO(by: playlistId, in: context) else { return }

    if let sourcePlacementMO = fetchPlacement(
      playlistId: playlistId, folderId: sourceFolderMO.id, in: context
    ) {
      context.delete(sourcePlacementMO)
    }

    let destinationServerId = destinationFolderMO.id
    let placementMO = fetchPlacement(
      playlistId: playlistId, folderId: destinationServerId, in: context
    ) ?? makePlacementMO(playlist: playlistMO, folderId: destinationServerId, in: context)
    placementMO.sortOrderValue = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: destinationServerId, in: context)
    )
    try? context.save()

    pushReplaceAllPlacements(playlistId: playlistId, in: context)
    notifyChange()
    exportCurrentTree()
  }

  /// Unfile a playlist completely — remove every placement it has, returning it
  /// to the implicit, unordered root.
  public func unfilePlaylist(_ playlistId: String) {
    guard let context = managedObjectContext else { return }
    let placements = fetchPlacements(playlistId: playlistId, in: context)
    guard !placements.isEmpty else { return }
    for placementMO in placements {
      context.delete(placementMO)
    }
    try? context.save()

    pushReplaceAllPlacements(playlistId: playlistId, in: context)
    notifyChange()
    exportCurrentTree()
  }

  /// Move a sibling — folder or playlist — to `targetIndex` within its parent's
  /// ordering space, assigning sortOrders by gap numbering and renumbering the
  /// siblings only when no gap remains.
  public func moveSibling(
    kind: PlaylistFolderSiblingKind,
    id siblingId: String,
    inFolder parentFolderId: UUID?,
    toIndex targetIndex: Int
  ) {
    guard let context = managedObjectContext else { return }

    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = findFolderMO(by: parentFolderId, in: context) else { return }
      parentServerId = parentFolderMO.id
    }

    let allSiblings = siblings(inFolderId: parentServerId, in: context)
    let otherSiblings = allSiblings.filter { !($0.kind == kind && $0.id == siblingId) }
    let sortOrderPlan = PlaylistFolderOrdering.insertionPlan(
      into: otherSiblings,
      targetIndex: targetIndex
    )

    var sortOrderUpdates = [PlaylistFolderSortOrderAssignment]()
    switch sortOrderPlan {
    case let .assign(sortOrder):
      sortOrderUpdates = [PlaylistFolderSortOrderAssignment(
        kind: kind, id: siblingId, sortOrder: sortOrder
      )]
    case let .renumberSiblings(assignments, insertedSortOrder):
      sortOrderUpdates = assignments
      sortOrderUpdates.append(PlaylistFolderSortOrderAssignment(
        kind: kind, id: siblingId, sortOrder: insertedSortOrder
      ))
    }

    for assignment in sortOrderUpdates {
      applySortOrderLocally(assignment, inFolderId: parentServerId, in: context)
    }
    try? context.save()

    if let api = navidromeApi {
      let serverUpdates = sortOrderUpdates
      let placementFolderId = parentServerId.isEmpty
        ? PlaylistFolderRootId.literal : parentServerId
      Task {
        for assignment in serverUpdates {
          switch assignment.kind {
          case .folder:
            try? await api.updateFolder(
              id: assignment.id, sortOrder: .set(assignment.sortOrder)
            )
          case .playlist:
            try? await api.setPlaylistPlacement(
              folderId: placementFolderId,
              playlistId: assignment.id,
              sortOrder: assignment.sortOrder
            )
          }
        }
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  // MARK: - Query

  public func folder(byId id: UUID) -> PlaylistFolder? {
    Self.findFolder(id: id, in: folders)
  }

  /// The complete ordering space of one parent — subfolders and placed
  /// playlists interleaved, in display order.
  public func orderedSiblings(inFolder parentFolderId: UUID?) -> [PlaylistFolderSibling] {
    guard let context = managedObjectContext else { return [] }
    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = findFolderMO(by: parentFolderId, in: context) else { return [] }
      parentServerId = parentFolderMO.id
    }
    return PlaylistFolderOrdering.sorted(siblings(inFolderId: parentServerId, in: context))
  }

  /// The placement sortOrder of each playlist placed directly in
  /// `parentFolderId` (or at the root when `nil`).
  ///
  /// Exposed so a view can apply its own filtering — offline, search, smart
  /// playlists — and still order whatever survives with the sibling comparator.
  /// Playlists absent from the result have no placement, so they sort last.
  public func playlistSortOrders(inFolder parentFolderId: UUID?) -> [String: Int] {
    guard let context = managedObjectContext else { return [:] }
    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = findFolderMO(by: parentFolderId, in: context) else { return [:] }
      parentServerId = parentFolderMO.id
    }
    var sortOrders = [String: Int]()
    for placementMO in fetchPlacements(folderId: parentServerId, in: context) {
      guard let playlistId = placementMO.playlist?.id,
            let sortOrder = placementMO.sortOrderValue else { continue }
      sortOrders[playlistId] = sortOrder
    }
    return sortOrders
  }

  // MARK: - Membership sync from playlist responses

  /// Replace a playlist's placements from the folder ids carried on its own API
  /// response. Placements the playlist already has keep their order; new ones
  /// append.
  public func syncMemberships(playlistId: String, folderIds: [String]) {
    guard let context = managedObjectContext else { return }
    guard let playlistMO = fetchPlaylistMO(by: playlistId, in: context) else { return }

    let desiredFolderIds = Set(folderIds.map { PlaylistFolderRootId.normalized($0) })
    let existingPlacements = fetchPlacements(playlistId: playlistId, in: context)

    for placementMO in existingPlacements
      where !desiredFolderIds.contains(placementMO.folderId) {
      context.delete(placementMO)
    }

    let existingFolderIds = Set(existingPlacements.map(\.folderId))
    for desiredFolderId in desiredFolderIds where !existingFolderIds.contains(desiredFolderId) {
      let placementMO = makePlacementMO(
        playlist: playlistMO, folderId: desiredFolderId, in: context
      )
      placementMO.sortOrderValue = PlaylistFolderOrdering.appendSortOrder(
        after: siblings(inFolderId: desiredFolderId, in: context)
      )
    }

    try? context.save()
  }

  // MARK: - Export safety net

  /// Serialize the whole folder tree to the Files-app-visible JSON snapshot.
  ///
  /// Called after every successful local mutation. Failures are logged, never
  /// propagated — the snapshot is a safety net, so it must never be able to fail
  /// the operation it exists to protect.
  func exportCurrentTree() {
    guard let context = managedObjectContext else { return }
    treeExporter.writeIgnoringFailure(buildExport(from: context))
  }

  func buildExport(from context: NSManagedObjectContext) -> PlaylistFolderTreeExport {
    let folderMOs = (try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []
    let exportFolders = folderMOs
      .map {
        PlaylistFolderExportFolder(
          id: $0.id,
          name: $0.name,
          parentId: PlaylistFolderRootId.normalized($0.parentId),
          sortOrder: $0.sortOrderValue
        )
      }
      .sorted { ($0.parentId, $0.name, $0.id) < ($1.parentId, $1.name, $1.id) }

    let exportPlacements = fetchPlacements(in: context)
      .compactMap { placementMO -> PlaylistFolderExportPlacement? in
        guard let playlistMO = placementMO.playlist else { return nil }
        return PlaylistFolderExportPlacement(
          playlistName: playlistMO.name ?? "",
          playlistId: playlistMO.id,
          folderId: placementMO.folderId,
          sortOrder: placementMO.sortOrderValue
        )
      }
      .sorted {
        ($0.folderId, $0.playlistName, $0.playlistId)
          < ($1.folderId, $1.playlistName, $1.playlistId)
      }

    return PlaylistFolderTreeExport(
      exportedAt: Date(),
      folders: exportFolders,
      placements: exportPlacements
    )
  }

  // MARK: - Notification

  func notifyChange() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  // MARK: - Static Helpers

  static func findFolder(id: UUID, in folders: [PlaylistFolder]) -> PlaylistFolder? {
    for folder in folders {
      if folder.id == id { return folder }
      if let found = findFolder(id: id, in: folder.subfolders) { return found }
    }
    return nil
  }
}
