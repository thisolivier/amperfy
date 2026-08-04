//
//  PlaylistFolderStore+Storage.swift
//  AmperfyKit
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

import CoreData
import Foundation

/// Core Data access for folders and placements, plus the tree/sibling
/// projections the rest of the store and the UI read.
extension PlaylistFolderStore {
  // MARK: - Tree building

  func buildFolderTree(from context: NSManagedObjectContext) -> [PlaylistFolder] {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    guard let allFolderMOs = try? context.fetch(fetchRequest) else { return [] }

    let placementsByFolderId = Dictionary(
      grouping: fetchPlacements(in: context),
      by: { $0.folderId }
    )

    let rootFolderMOs = allFolderMOs.filter { PlaylistFolderRootId.isRoot($0.parentId) }
    let rootFolders = rootFolderMOs.map {
      buildPlaylistFolder(
        from: $0,
        allFolderMOs: allFolderMOs,
        placementsByFolderId: placementsByFolderId
      )
    }
    // Top-level folders order against each other by the same sibling rules.
    return sortFoldersAsSiblings(rootFolders)
  }

  private func buildPlaylistFolder(
    from folderMO: PlaylistFolderMO,
    allFolderMOs: [PlaylistFolderMO],
    placementsByFolderId: [String: [PlaylistFolderPlacementMO]]
  )
    -> PlaylistFolder {
    let childFolderMOs = allFolderMOs.filter { $0.parentId == folderMO.id }
    let subfolders = childFolderMOs.map {
      buildPlaylistFolder(
        from: $0,
        allFolderMOs: allFolderMOs,
        placementsByFolderId: placementsByFolderId
      )
    }

    let placements = placementsByFolderId[folderMO.id] ?? []
    let orderedPlaylistIds = PlaylistFolderOrdering
      .sorted(placements.compactMap(playlistSibling(for:)))
      .map(\.id)

    return PlaylistFolder(
      id: UUID(uuidString: folderMO.id) ?? UUID(),
      name: folderMO.name,
      playlistIds: orderedPlaylistIds,
      subfolders: sortFoldersAsSiblings(subfolders),
      sortOrder: folderMO.sortOrderValue
    )
  }

  /// Order a set of already-built folders by the sibling comparator. Folders
  /// interleave with playlists in the real ordering space; this is that same
  /// order projected onto the folders alone, which is what the tree type can
  /// express.
  private func sortFoldersAsSiblings(_ folders: [PlaylistFolder]) -> [PlaylistFolder] {
    folders
      .map { folder in
        (
          folder: folder,
          sibling: PlaylistFolderSibling(
            kind: .folder,
            id: folder.id.uuidString,
            name: folder.name,
            sortOrder: folder.sortOrder
          )
        )
      }
      .sorted { PlaylistFolderOrdering.isOrderedBefore($0.sibling, $1.sibling) }
      .map(\.folder)
  }

  // MARK: - Siblings

  /// Every sibling of one parent — its subfolders and the playlists placed
  /// directly in it — unsorted. `folderId` is the *server* id; the empty string
  /// is the root.
  func siblings(
    inFolderId parentServerId: String,
    in context: NSManagedObjectContext
  )
    -> [PlaylistFolderSibling] {
    var siblings = fetchChildFolders(of: parentServerId, in: context).map {
      PlaylistFolderSibling(
        kind: .folder,
        id: $0.id,
        name: $0.name,
        sortOrder: $0.sortOrderValue
      )
    }
    siblings.append(contentsOf: fetchPlacements(folderId: parentServerId, in: context)
      .compactMap(playlistSibling(for:)))
    return siblings
  }

  private func playlistSibling(for placementMO: PlaylistFolderPlacementMO)
    -> PlaylistFolderSibling? {
    guard let playlistMO = placementMO.playlist else { return nil }
    return PlaylistFolderSibling(
      kind: .playlist,
      id: playlistMO.id,
      name: playlistMO.name ?? "",
      sortOrder: placementMO.sortOrderValue
    )
  }

  /// Write one planned sortOrder assignment to local storage.
  func applySortOrderLocally(
    _ assignment: PlaylistFolderSortOrderAssignment,
    inFolderId parentServerId: String,
    in context: NSManagedObjectContext
  ) {
    switch assignment.kind {
    case .folder:
      fetchFolderMO(byServerId: assignment.id, in: context)?
        .sortOrderValue = assignment.sortOrder
    case .playlist:
      fetchPlacement(
        playlistId: assignment.id, folderId: parentServerId, in: context
      )?.sortOrderValue = assignment.sortOrder
    }
  }

  // MARK: - Folder fetches

  func findFolderMO(by uuid: UUID, in context: NSManagedObjectContext) -> PlaylistFolderMO? {
    fetchFolderMO(byServerId: uuid.uuidString, in: context)
  }

  func fetchFolderMO(byServerId serverId: String, in context: NSManagedObjectContext)
    -> PlaylistFolderMO? {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", serverId)
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  func fetchChildFolders(of parentServerId: String, in context: NSManagedObjectContext)
    -> [PlaylistFolderMO] {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    if PlaylistFolderRootId.isRoot(parentServerId) {
      fetchRequest.predicate = NSPredicate(format: "parentId == nil OR parentId == %@", "")
    } else {
      fetchRequest.predicate = NSPredicate(format: "parentId == %@", parentServerId)
    }
    return (try? context.fetch(fetchRequest)) ?? []
  }

  func fetchPlaylistMO(by playlistId: String, in context: NSManagedObjectContext) -> PlaylistMO? {
    let fetchRequest = PlaylistMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", playlistId)
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  /// Whether re-parenting `movingFolderId` under `intoParentId` would make the
  /// folder its own ancestor. Mirrors the server's 400-on-cycle rule.
  func wouldCreateCycle(
    movingFolderId: String,
    intoParentId: String,
    in context: NSManagedObjectContext
  )
    -> Bool {
    if PlaylistFolderRootId.isRoot(intoParentId) { return false }
    if intoParentId == movingFolderId { return true }

    var visitedFolderIds = Set<String>()
    var currentFolderId: String? = intoParentId
    while let folderId = currentFolderId, !PlaylistFolderRootId.isRoot(folderId) {
      if folderId == movingFolderId { return true }
      // Defensive: a pre-existing cycle must not spin here forever.
      guard visitedFolderIds.insert(folderId).inserted else { return true }
      currentFolderId = fetchFolderMO(byServerId: folderId, in: context)?.parentId
    }
    return false
  }

  // MARK: - Placement fetches

  func fetchPlacements(in context: NSManagedObjectContext) -> [PlaylistFolderPlacementMO] {
    (try? context.fetch(PlaylistFolderPlacementMO.fetchRequest())) ?? []
  }

  func fetchPlacements(folderId: String, in context: NSManagedObjectContext)
    -> [PlaylistFolderPlacementMO] {
    let fetchRequest = PlaylistFolderPlacementMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(
      format: "folderId == %@", PlaylistFolderRootId.normalized(folderId)
    )
    return (try? context.fetch(fetchRequest)) ?? []
  }

  func fetchPlacements(playlistId: String, in context: NSManagedObjectContext)
    -> [PlaylistFolderPlacementMO] {
    let fetchRequest = PlaylistFolderPlacementMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "playlist.id == %@", playlistId)
    return (try? context.fetch(fetchRequest)) ?? []
  }

  func fetchPlacement(
    playlistId: String,
    folderId: String,
    in context: NSManagedObjectContext
  )
    -> PlaylistFolderPlacementMO? {
    let fetchRequest = PlaylistFolderPlacementMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(
      format: "playlist.id == %@ AND folderId == %@",
      playlistId,
      PlaylistFolderRootId.normalized(folderId)
    )
    fetchRequest.fetchLimit = 1
    return (try? context.fetch(fetchRequest))?.first
  }

  @discardableResult
  func makePlacementMO(
    playlist playlistMO: PlaylistMO,
    folderId: String,
    in context: NSManagedObjectContext
  )
    -> PlaylistFolderPlacementMO {
    let placementMO = PlaylistFolderPlacementMO(context: context)
    placementMO.playlist = playlistMO
    placementMO.folderId = PlaylistFolderRootId.normalized(folderId)
    placementMO.account = accountMO
    return placementMO
  }

  /// Carry every reference to an optimistic local folder id over to the
  /// server-assigned one, once a create round-trips.
  func repointFolderReferences(
    from optimisticFolderId: String,
    to serverFolderId: String,
    in context: NSManagedObjectContext
  ) {
    guard optimisticFolderId != serverFolderId else { return }
    for placementMO in fetchPlacements(folderId: optimisticFolderId, in: context) {
      placementMO.folderId = serverFolderId
    }
    for childFolderMO in fetchChildFolders(of: optimisticFolderId, in: context) {
      childFolderMO.parentId = serverFolderId
    }
  }

  // MARK: - Server write helper

  /// Push a playlist's complete local placement set with the replace-all
  /// endpoint — the contract's move primitive.
  func pushReplaceAllPlacements(playlistId: String, in context: NSManagedObjectContext) {
    guard let api = navidromeApi else { return }
    let placements = fetchPlacements(playlistId: playlistId, in: context).map {
      NavidromePlacementWrite(
        folderId: $0.folderId.isEmpty ? PlaylistFolderRootId.literal : $0.folderId,
        sortOrder: $0.sortOrderValue
      )
    }
    Task {
      try? await api.replacePlaylistPlacements(
        playlistId: playlistId, placements: placements
      )
    }
  }
}
