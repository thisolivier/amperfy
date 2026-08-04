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

// MARK: - PlaylistFolderCreateRequester

/// Issues `POST /api/playlist/folder`.
///
/// Injectable for the same reason the probe and the delete are, and with more at
/// stake: a folder is created optimistically and then *adopts the id the server
/// assigns it*, carrying across anything filed into it in the meantime. That
/// adoption is the flow a folder-tree rebuild leans on hardest — dozens of
/// creates in one sitting, each racing whatever the user does next — and it
/// cannot be exercised at all without a seam here.
public typealias PlaylistFolderCreateRequester =
  @Sendable (_ name: String, _ parentId: String?, _ sortOrder: Int?) async throws
    -> NavidromeOrganizationFolder

// MARK: - PlaylistFolderPlacementUpsertRequester

/// Issues `PUT /api/playlist/folder/{id}/playlist/{playlistId}`.
///
/// Injectable because placements filed into a folder while its create was still
/// pending never reached the server — the folder had no server id to file them
/// against — so they have to be replayed at adoption, and that replay is the
/// difference between a rebuilt tree surviving the next sync and being stripped
/// back to whatever the server happened to know.
public typealias PlaylistFolderPlacementUpsertRequester =
  @Sendable (_ folderId: String, _ playlistId: String, _ sortOrder: Int?) async throws -> ()

// MARK: - PlaylistFolderDeleteRequester

/// Issues `DELETE /api/playlist/folder/{id}`.
///
/// Injectable for the same reason the probe is: folder delete now hands the
/// promotion of the folder's placements entirely to the server, so what the
/// client must be shown to do is issue this one request and then re-sync — never
/// a placement write of its own.
public typealias PlaylistFolderDeleteRequester =
  @Sendable (String) async throws -> ()

// MARK: - PlaylistFolder

public struct PlaylistFolder: Codable, Identifiable, Equatable {
  /// The server's folder id, verbatim.
  ///
  /// Opaque and **case sensitive**: Navidrome mints these with `id.NewRandom()`,
  /// a 22-character nanoid over `[0-9A-Za-z]`. They are not UUIDs, they are not
  /// parseable as UUIDs, and two ids differing only in case are two different
  /// folders. Nothing may normalize, re-case, or round-trip this string through
  /// another type.
  public let id: String
  public var name: String
  /// Playlist ids placed directly in this folder, already in sibling order.
  public var playlistIds: [String]
  /// Direct subfolders, already in sibling order.
  public var subfolders: [PlaylistFolder]
  /// This folder's own position among its siblings. `nil` means unordered,
  /// which sorts after every ordered sibling.
  public var sortOrder: Int?

  public init(
    id: String = PlaylistFolder.makeTemporaryId(),
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

  /// Marks an id as local-only. Chosen so it can never collide with a server id:
  /// Navidrome nanoids are 22 characters of `[0-9A-Za-z]`, with no punctuation.
  public static let temporaryIdPrefix = "pending-local:"

  /// A local id for a folder that does not have a server id yet.
  ///
  /// A folder is created optimistically so the UI can respond at once, which
  /// means something has to identify it during the round trip. This id is
  /// replaced by the server's own once the POST returns — see
  /// `adoptServerFolder(folderMO:response:in:)`.
  ///
  /// The id is not merely a placeholder, it is a *record of pending work*. A
  /// folder still carrying one is a create that has not landed yet, and that is
  /// the whole pending-create queue: it is already durable, already ordered by
  /// the folder tree, and already carries the name, parent and sortOrder the
  /// retry needs. A second queue structure alongside it could only disagree
  /// with it.
  public static func makeTemporaryId() -> String {
    "\(temporaryIdPrefix)\(UUID().uuidString)"
  }

  /// Whether `folderId` names a folder the server has never confirmed.
  ///
  /// Everything about such a folder is local-only until it adopts a real id:
  /// renames, moves, deletes and placement writes all skip the network, because
  /// every one of them would name an id the server has never issued.
  public static func isTemporaryId(_ folderId: String) -> Bool {
    folderId.hasPrefix(temporaryIdPrefix)
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
  var folderCreateRequester: PlaylistFolderCreateRequester?
  var placementUpsertRequester: PlaylistFolderPlacementUpsertRequester?
  var folderDeleteRequester: PlaylistFolderDeleteRequester?
  var treeExporter: PlaylistFolderTreeExporter

  let logger = Logger(
    subsystem: "dev.thisolivier.amperfy",
    category: "PlaylistFolderSync"
  )
  /// Guards the "server has no folder API" warning so a per-sync condition does
  /// not spam the log on every library refresh.
  var hasLoggedServerLacksFolderApi = false

  /// How many nested ``performBatchedUpdates(_:)`` calls are in flight. While
  /// this is above zero, change notifications and tree exports are held back and
  /// coalesced — see `PlaylistFolderStore+Batching.swift`.
  var batchedUpdateDepth = 0
  /// Whether anything inside the running batch asked to notify.
  var hasDeferredChangeNotification = false
  /// Whether anything inside the running batch asked to export.
  var hasDeferredTreeExport = false

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
      let createRequester: PlaylistFolderCreateRequester = { name, parentId, sortOrder in
        try await api.createFolder(name: name, parentId: parentId, sortOrder: sortOrder)
      }
      folderCreateRequester = createRequester
      let placementUpsertRequester: PlaylistFolderPlacementUpsertRequester =
        { folderId, playlistId, sortOrder in
          try await api.setPlaylistPlacement(
            folderId: folderId, playlistId: playlistId, sortOrder: sortOrder
          )
        }
      self.placementUpsertRequester = placementUpsertRequester
      let deleteRequester: PlaylistFolderDeleteRequester = { folderId in
        try await api.deleteFolder(id: folderId)
      }
      folderDeleteRequester = deleteRequester
    } else {
      folderOrganizationFetcher = nil
      folderCreateRequester = nil
      placementUpsertRequester = nil
      folderDeleteRequester = nil
    }
    hasLoggedServerLacksFolderApi = false
    backfillPlacementsFromLegacyMembershipsIfNeeded(in: context)
  }

  /// Test seam: configure the destructive sync path without a live Navidrome
  /// client, supplying the capability probe and the delete request directly.
  func configureForTesting(
    context: NSManagedObjectContext,
    account: AccountMO?,
    organizationFetcher: PlaylistFolderOrganizationFetcher? = nil,
    folderCreateRequester: PlaylistFolderCreateRequester? = nil,
    placementUpsertRequester: PlaylistFolderPlacementUpsertRequester? = nil,
    folderDeleteRequester: PlaylistFolderDeleteRequester? = nil,
    treeExporter: PlaylistFolderTreeExporter? = nil
  ) {
    managedObjectContext = context
    navidromeApi = nil
    accountMO = account
    folderOrganizationFetcher = organizationFetcher
    self.folderCreateRequester = folderCreateRequester
    self.placementUpsertRequester = placementUpsertRequester
    self.folderDeleteRequester = folderDeleteRequester
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

  /// All playlist IDs placed in at least one real folder at any depth — that is,
  /// the playlists a root listing should *not* also show.
  ///
  /// An explicit root placement is deliberately excluded. Note this reads the
  /// opposite way to the word "filed" in the API contract, which calls an
  /// explicit root placement "filed" to distinguish it (ordered at root) from a
  /// playlist with no placement at all (unordered at root). That distinction is
  /// preserved here — it lives in ``playlistSortOrders(inFolder:)``, where an
  /// explicit root placement has a sortOrder and an absent one does not.
  ///
  /// This property answers a different question: *is this playlist somewhere
  /// other than the root?* Folding explicit root placements in would drop those
  /// playlists from the root listing, and since they live at the root, they would
  /// simply vanish from the UI.
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
  public func createFolder(name: String, parent: String?) -> PlaylistFolder {
    guard let context = managedObjectContext else {
      return legacyCreateFolder(name: name, parent: parent)
    }

    let newFolder = PlaylistFolder(name: name)

    // Resolve the parent, if one was named. An unknown parent leaves the new
    // folder at the root rather than failing — the same shape as before.
    var parentServerId: String?
    if let parent,
       let parentMO = fetchFolderMO(byServerId: parent, in: context) {
      parentServerId = parentMO.id
    }

    // A new folder lands after everything already in its parent.
    let appendSortOrder = PlaylistFolderOrdering.appendSortOrder(
      after: siblings(inFolderId: PlaylistFolderRootId.normalized(parentServerId), in: context)
    )

    // Create in CoreData immediately (optimistic)
    let folderMO = PlaylistFolderMO(context: context)
    folderMO.id = newFolder.id
    folderMO.name = name
    folderMO.parentId = parentServerId
    folderMO.sortOrderValue = appendSortOrder
    folderMO.account = accountMO
    try? context.save()

    // Fire-and-forget server creation
    if let folderCreateRequester {
      nonisolated(unsafe) let unsafeFolderMO = folderMO
      nonisolated(unsafe) let unsafeContext = context
      Task {
        do {
          let serverResponse = try await folderCreateRequester(
            name, parentServerId, appendSortOrder
          )
          let placementsToPush = await MainActor.run {
            self.adoptServerFolder(
              folderMO: unsafeFolderMO, response: serverResponse, in: unsafeContext
            )
          }
          await self.pushPlacements(placementsToPush, toFolderId: serverResponse.id)
        } catch {
          // The folder keeps its temporary id and stays on this device. That is
          // not a dead end: it *is* the pending-create queue, and the next sync
          // re-attempts the POST. See `retryPendingFolderCreations(in:)`.
        }
      }
    }

    notifyChange()
    exportCurrentTree()
    return newFolder
  }

  public func renameFolder(id: String, to name: String) {
    guard let context = managedObjectContext else {
      legacyRenameFolder(id: id, to: name)
      return
    }

    guard let folderMO = fetchFolderMO(byServerId: id, in: context) else { return }
    let serverId = folderMO.id
    folderMO.name = name
    try? context.save()

    // A pending folder is local-only: the server has never issued this id, so
    // the rename would 404. The create that eventually lands carries the current
    // name anyway.
    if let api = navidromeApi, !PlaylistFolder.isTemporaryId(serverId) {
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
  public func moveFolder(id: String, toParent newParentFolderId: String?) {
    guard let context = managedObjectContext else { return }
    guard let folderMO = fetchFolderMO(byServerId: id, in: context) else { return }

    var newParentServerId: String?
    if let newParentFolderId {
      guard let newParentMO = fetchFolderMO(byServerId: newParentFolderId, in: context)
      else { return }
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

    // Skipped for a pending folder, and equally for a move *into* one: the
    // create POST will carry whichever parent the folder has when it lands.
    if let api = navidromeApi,
       !PlaylistFolder.isTemporaryId(serverId),
       !PlaylistFolder.isTemporaryId(normalizedNewParentId) {
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

  /// Deletes the folder with the given id. Child folders and the folder's
  /// playlists are lifted one level, into the containing folder (root if the
  /// folder was at root). Grandchildren remain inside their direct parent — the
  /// pop is one level only. Playlists themselves are never deleted.
  ///
  /// **The promotion is the server's job, and its result is fetched rather than
  /// predicted.** `DELETE /api/playlist/folder/{id}` re-parents child folders
  /// and promotes the folder's placements to the deleted folder's parent, with
  /// the existing home winning on conflict and sortOrder carried verbatim. That
  /// last rule means a delete can legitimately *reduce* the placement count: a
  /// playlist filed in both the folder and its parent ends up with one placement
  /// on the parent's terms, not the promoted one's. Any local guess at the
  /// outcome would drift on exactly that case, so once the delete succeeds the
  /// organization is re-fetched and run back through the ordinary
  /// capability-gated reconciliation.
  ///
  /// Locally only the two deterministic parts are applied up front, so the UI
  /// responds immediately: the folder disappears and its child folders re-parent.
  /// Its placements are dropped rather than re-pointed — an edge into a folder
  /// that no longer exists means nothing — which shows the affected playlists at
  /// the root for the moment before the refetch files them into the parent.
  /// Nothing is destroyed by that transient state, and if the delete fails the
  /// refetch puts the folder straight back.
  public func deleteFolder(id: String) {
    guard let context = managedObjectContext else {
      legacyDeleteFolder(id: id)
      return
    }

    guard let folderMO = fetchFolderMO(byServerId: id, in: context) else { return }
    let serverId = folderMO.id
    let parentId = folderMO.parentId

    // Re-parent child folders: contract-guaranteed, so safe to apply locally.
    for childFolderMO in fetchChildFolders(of: serverId, in: context) {
      childFolderMO.parentId = parentId
    }

    for placementMO in fetchPlacements(folderId: serverId, in: context) {
      context.delete(placementMO)
    }

    context.delete(folderMO)
    try? context.save()

    // Deleting a folder the server never heard of is nothing to report to it.
    if let folderDeleteRequester, !PlaylistFolder.isTemporaryId(serverId) {
      Task {
        try? await folderDeleteRequester(serverId)
        // Converge on the server's promotion rather than guessing at it. This
        // deliberately reuses the capability-gated sync path instead of adding a
        // write path of its own.
        try? await self.syncFromServer()
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  // MARK: - Placements

  public func addPlaylists(_ playlistIds: [String], to folderId: String) {
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

    guard let folderMO = fetchFolderMO(byServerId: folderId, in: context) else { return }
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

    // Placements into a pending folder stay local. They are replayed the moment
    // the folder adopts a real id — see `pushPlacements(ofFolderId:in:)` — which
    // is the only point at which the server can accept them.
    if let placementUpsertRequester, !PlaylistFolder.isTemporaryId(serverId) {
      let placementsToWrite = appendedSortOrders
      Task {
        for placement in placementsToWrite {
          try? await placementUpsertRequester(
            serverId, placement.playlistId, placement.sortOrder
          )
        }
      }
    }

    notifyChange()
    exportCurrentTree()
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: String) {
    guard let context = managedObjectContext else {
      legacyRemovePlaylists(playlistIds, from: folderId)
      return
    }

    guard let folderMO = fetchFolderMO(byServerId: folderId, in: context) else { return }
    let serverId = folderMO.id

    for playlistId in playlistIds {
      guard let placementMO = fetchPlacement(
        playlistId: playlistId, folderId: serverId, in: context
      ) else { continue }
      context.delete(placementMO)
    }
    try? context.save()

    if let api = navidromeApi, !PlaylistFolder.isTemporaryId(serverId) {
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
    _ playlistId: String, from sourceFolderId: String, to destFolderId: String
  ) {
    guard let context = managedObjectContext else {
      legacyRemovePlaylists([playlistId], from: sourceFolderId)
      legacyAddPlaylists([playlistId], to: destFolderId)
      return
    }

    guard let sourceFolderMO = fetchFolderMO(byServerId: sourceFolderId, in: context),
          let destinationFolderMO = fetchFolderMO(byServerId: destFolderId, in: context),
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
    inFolder parentFolderId: String?,
    toIndex targetIndex: Int
  ) {
    guard let context = managedObjectContext else { return }

    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = fetchFolderMO(byServerId: parentFolderId, in: context)
      else { return }
      parentServerId = parentFolderMO.id
    }

    // Folder ids are opaque and case sensitive, so the id the UI holds is the
    // stored id exactly — nothing to normalize. Only its existence is worth
    // checking, so an id for a folder that has since been deleted does not
    // renumber the siblings around a gap that will never be filled.
    if kind == .folder {
      guard fetchFolderMO(byServerId: siblingId, in: context) != nil else { return }
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

    // Ordering inside a pending folder is local until the folder exists on the
    // server; the placement replay at adoption carries the sortOrders with it.
    if let api = navidromeApi, !PlaylistFolder.isTemporaryId(parentServerId) {
      let serverUpdates = sortOrderUpdates
      let placementFolderId = parentServerId.isEmpty
        ? PlaylistFolderRootId.literal : parentServerId
      Task {
        for assignment in serverUpdates {
          switch assignment.kind {
          case .folder:
            // A pending sibling has no server row to reorder yet.
            guard !PlaylistFolder.isTemporaryId(assignment.id) else { continue }
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

  public func folder(byId id: String) -> PlaylistFolder? {
    Self.findFolder(id: id, in: folders)
  }

  /// The complete ordering space of one parent — subfolders and placed
  /// playlists interleaved, in display order.
  public func orderedSiblings(inFolder parentFolderId: String?) -> [PlaylistFolderSibling] {
    guard let context = managedObjectContext else { return [] }
    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = fetchFolderMO(byServerId: parentFolderId, in: context)
      else { return [] }
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
  public func playlistSortOrders(inFolder parentFolderId: String?) -> [String: Int] {
    guard let context = managedObjectContext else { return [:] }
    var parentServerId = PlaylistFolderRootId.canonical
    if let parentFolderId {
      guard let parentFolderMO = fetchFolderMO(byServerId: parentFolderId, in: context)
      else { return [:] }
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
    guard batchedUpdateDepth == 0 else {
      // A bulk organization pass is running. Exporting once per item would write
      // the snapshot dozens of times for one user action, each write rolling the
      // previous generation — which would destroy the last pre-operation copy
      // the safety net exists to keep. One export at the end of the batch.
      hasDeferredTreeExport = true
      return
    }
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
    guard batchedUpdateDepth == 0 else {
      // Every observer of this notification reloads a whole table. Posting it
      // per item during a bulk move would rebuild the list under the user's
      // pointer mid-drag.
      hasDeferredChangeNotification = true
      return
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  // MARK: - Static Helpers

  static func findFolder(id: String, in folders: [PlaylistFolder]) -> PlaylistFolder? {
    for folder in folders {
      if folder.id == id { return folder }
      if let found = findFolder(id: id, in: folder.subfolders) { return found }
    }
    return nil
  }
}
