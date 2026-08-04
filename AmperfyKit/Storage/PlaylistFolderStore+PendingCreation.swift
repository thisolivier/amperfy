//
//  PlaylistFolderStore+PendingCreation.swift
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

/// Folders whose creation has not reached the server yet, and how they get
/// there.
///
/// A folder is created optimistically under a temporary id so the UI responds at
/// once. Usually the POST returns a moment later and the folder adopts the
/// server's id. When it does not — offline, a flaky connection, a server
/// restart mid-rebuild — the folder simply stays under its temporary id.
///
/// **Those folders are the pending-create queue.** They are already durable,
/// already ordered by the tree, and already carry the name, parent and sortOrder
/// a retry needs. A separate persisted queue could only ever disagree with them.
/// So the retry is a scan, not a drain: every sync, before anything is fetched,
/// each still-pending folder is re-POSTed.
///
/// Two rules make that safe:
/// - A pending folder is **local-only**. Nothing about it is sent to the server
///   until it adopts a real id, because every such request would name an id the
///   server has never issued. See `PlaylistFolder.isTemporaryId(_:)`.
/// - Reconciliation must **never delete** a pending folder for being absent from
///   the server envelope. It is local-first state awaiting push, not server
///   state to be mirrored. See `reconcileFolders`.
extension PlaylistFolderStore {
  // MARK: - Finding pending work

  /// Every folder still carrying a temporary id, parents before children.
  ///
  /// The order matters: a pending child's `parentId` may itself be a pending
  /// parent's temporary id, and the child cannot be created until that parent
  /// has a real id to be filed under.
  @MainActor
  func pendingFolderIdsInCreationOrder(
    in context: NSManagedObjectContext
  )
    -> [String] {
    let allFolderMOs = (try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []
    let pendingFolderMOs = allFolderMOs.filter { PlaylistFolder.isTemporaryId($0.id) }
    guard !pendingFolderMOs.isEmpty else { return [] }

    let pendingFolderIds = Set(pendingFolderMOs.map(\.id))
    var orderedFolderMOs = [PlaylistFolderMO]()
    var placedFolderIds = Set<String>()

    // Repeatedly take every pending folder whose parent is either not pending or
    // already placed. Anything left after a pass that placed nothing is part of
    // a parent cycle, which the tree should make impossible; it is appended
    // rather than dropped so a corrupt tree still gets its creates attempted.
    var remainingFolderMOs = pendingFolderMOs
    while !remainingFolderMOs.isEmpty {
      let readyFolderMOs = remainingFolderMOs.filter { folderMO in
        guard let parentId = folderMO.parentId, pendingFolderIds.contains(parentId)
        else { return true }
        return placedFolderIds.contains(parentId)
      }
      guard !readyFolderMOs.isEmpty else {
        orderedFolderMOs.append(contentsOf: remainingFolderMOs)
        break
      }
      orderedFolderMOs.append(contentsOf: readyFolderMOs)
      placedFolderIds.formUnion(readyFolderMOs.map(\.id))
      let readyFolderIds = Set(readyFolderMOs.map(\.id))
      remainingFolderMOs.removeAll { readyFolderIds.contains($0.id) }
    }
    // Ids, not objects: a managed object cannot cross an actor boundary, and the
    // retry loop below has to await between folders. A pending folder's *own* id
    // is stable across the pass — adoption rewrites its children's `parentId`,
    // never their ids — so an id stays a valid handle throughout.
    return orderedFolderMOs.map(\.id)
  }

  // MARK: - Retrying

  /// Re-attempt every pending folder creation. Called at the top of
  /// ``syncFromServer()``, before the organization is fetched, so a folder that
  /// lands here is already in the envelope that follows and reconciliation sees
  /// a consistent tree.
  ///
  /// Failures are left pending: there is no ceiling and no backoff because the
  /// retry rate is already bounded by how often a sync runs, and a folder the
  /// user made is not something to give up on.
  func retryPendingFolderCreations(in context: NSManagedObjectContext) async {
    guard folderCreateRequester != nil else { return }

    let pendingFolderIds = await MainActor.run {
      self.pendingFolderIdsInCreationOrder(in: context)
    }
    guard !pendingFolderIds.isEmpty else { return }

    var failureCount = 0
    for pendingFolderId in pendingFolderIds {
      let didAdopt = await retryCreation(ofFolderId: pendingFolderId, in: context)
      if !didAdopt { failureCount += 1 }
    }

    // One line per sync pass rather than one per folder: a long offline spell
    // should not fill the log with the same news repeated.
    if failureCount > 0 {
      logger.warning(
        """
        \(failureCount, privacy: .public) of \(pendingFolderIds.count, privacy: .public) \
        pending playlist folder(s) still could not be created on the server. They \
        remain on this device and will be retried on the next sync.
        """
      )
    } else {
      logger.info(
        """
        Created \(pendingFolderIds.count, privacy: .public) pending playlist \
        folder(s) on the server.
        """
      )
    }
  }

  /// - Returns: whether the folder adopted a server id.
  private func retryCreation(
    ofFolderId pendingFolderId: String,
    in context: NSManagedObjectContext
  )
    async -> Bool {
    guard let folderCreateRequester else { return false }

    // Read the request now rather than when the pass began: a parent that
    // adopted earlier in this same pass has already rewritten this folder's
    // parentId, and that rewritten value is the one to send.
    let createRequest = await MainActor.run {
      self.fetchFolderMO(byServerId: pendingFolderId, in: context).map {
        (name: $0.name, parentId: $0.parentId, sortOrder: $0.sortOrderValue)
      }
    }
    guard let createRequest else { return false }

    // Defensive: a pending parent that never adopted leaves its children
    // pointing at a temporary id. Sending that would create the child at the
    // root, silently flattening the tree, so the child stays pending too and
    // both are retried together next time.
    if let parentId = createRequest.parentId, PlaylistFolder.isTemporaryId(parentId) {
      return false
    }

    do {
      let serverResponse = try await folderCreateRequester(
        createRequest.name, createRequest.parentId, createRequest.sortOrder
      )
      let placementsToPush = await MainActor.run {
        self.fetchFolderMO(byServerId: pendingFolderId, in: context).map {
          self.adoptServerFolder(folderMO: $0, response: serverResponse, in: context)
        }
      }
      guard let placementsToPush else { return false }
      // Awaited, not fired off: the organization is fetched immediately after
      // this pass, and it has to see these placements.
      await pushPlacements(placementsToPush, toFolderId: serverResponse.id)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Adoption

  /// Swap a folder from its temporary id to the server's, and hand back the
  /// placements that now need replaying.
  ///
  /// Shared by the optimistic create's own callback and by the retry above, so
  /// the two cannot drift.
  ///
  /// The replay is the part that is easy to miss. While the folder was pending,
  /// every playlist filed into it wrote a placement locally and sent nothing —
  /// there was no server id to file against. Adopting an id does not
  /// retroactively tell the server about those placements, so without the replay
  /// the very next reconciliation finds a folder the server knows and no
  /// placements in it, and deletes every one of them.
  ///
  /// The push is deliberately *not* started here. During a sync pass the
  /// organization is fetched moments later, and a fire-and-forget push would
  /// race it: the fetch could return before the upserts landed, and
  /// reconciliation would strip exactly the placements this exists to save. So
  /// the caller gets the list and awaits ``pushPlacements(_:toFolderId:)`` at a
  /// point where that ordering is guaranteed.
  @MainActor
  func adoptServerFolder(
    folderMO: PlaylistFolderMO,
    response: NavidromeOrganizationFolder,
    in context: NSManagedObjectContext
  )
    -> [PlaylistFolderPlacementPush] {
    let temporaryFolderId = folderMO.id
    folderMO.id = response.id
    folderMO.parentId = response.normalizedParentId
    if let serverSortOrder = response.sortOrder {
      folderMO.sortOrderValue = serverSortOrder
    }
    // Carries placements and child folders made against the temporary id across.
    repointFolderReferences(from: temporaryFolderId, to: response.id, in: context)
    try? context.save()

    // Recorded before anything is announced, so an observer reacting to the
    // notifications below already resolves the old id to the new one.
    recordFolderIdAdoption(temporaryFolderId: temporaryFolderId, serverFolderId: response.id)
    exportCurrentTree()

    let adoption = PlaylistFolderAdoption(
      temporaryFolderId: temporaryFolderId,
      serverFolderId: response.id
    )
    NotificationCenter.default.post(
      name: PlaylistFolderStore.didAdoptFolderIdNotification,
      object: self,
      userInfo: adoption.asNotificationUserInfo
    )
    // And the general change too. Adoption rewrites a folder's identity, which
    // is as much a change as a rename; leaving it unannounced was what let a
    // screen sit on a dead id until some unrelated reload knocked it over.
    notifyChange()

    return fetchPlacements(folderId: response.id, in: context)
      .compactMap { placementMO in
        guard let playlistId = placementMO.playlist?.id, !playlistId.isEmpty
        else { return nil }
        return PlaylistFolderPlacementPush(
          playlistId: playlistId, sortOrder: placementMO.sortOrderValue
        )
      }
  }

  /// Upsert placements against a folder that now has a real id, so the server
  /// holds what this device does.
  func pushPlacements(
    _ placements: [PlaylistFolderPlacementPush],
    toFolderId serverFolderId: String
  ) async {
    guard let placementUpsertRequester,
          !PlaylistFolder.isTemporaryId(serverFolderId),
          !placements.isEmpty else { return }
    for placement in placements {
      try? await placementUpsertRequester(
        serverFolderId, placement.playlistId, placement.sortOrder
      )
    }
  }
}

// MARK: - PlaylistFolderPlacementPush

/// One placement waiting to be told to the server after its folder adopts a real
/// id.
public struct PlaylistFolderPlacementPush: Sendable, Equatable {
  public let playlistId: String
  public let sortOrder: Int?
}
