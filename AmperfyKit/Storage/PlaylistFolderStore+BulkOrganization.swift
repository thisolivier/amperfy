//
//  PlaylistFolderStore+BulkOrganization.swift
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

/// The write paths behind bulk organization: dragging a multi-row selection onto
/// a folder, the edit-mode toolbar actions, and "New folder from selection".
///
/// Each one is a thin arrangement of the existing single-item primitives inside
/// ``performBatchedUpdates(_:)``, so the change notification and the JSON export
/// fire exactly once for one user action, and no new server write path is
/// introduced — everything still goes through the endpoints the v2 contract
/// froze.
extension PlaylistFolderStore {
  // MARK: - Folder reference resolution

  /// The server folder id behind a UI-level folder reference, where `nil` means
  /// the root. Returns `nil` when a folder id does not resolve, which the caller
  /// must treat as "abort", not as "root".
  func resolveServerFolderId(
    _ folderId: String?,
    in context: NSManagedObjectContext
  )
    -> String? {
    guard let folderId else { return PlaylistFolderRootId.canonical }
    return fetchFolderMO(byServerId: folderId, in: context)?.id
  }

  // MARK: - Moving playlists

  /// Move playlists out of one folder and into another, where `nil` on either
  /// side means the root.
  ///
  /// This is the plural form of ``movePlaylist(_:from:to:)`` and keeps its
  /// semantics exactly: only the placement in the *source* folder is replaced.
  /// A playlist filed in both A and B, moved from A into C, ends up in C and B —
  /// multiplicity is the point of placements, so a move must not quietly
  /// collapse a playlist's other homes.
  ///
  /// Moving *to* the root creates an explicit root placement rather than
  /// dropping every placement: the user asked for this level, and at the root
  /// "this level, in this position" is what an explicit root placement means.
  /// Unfiling entirely stays ``unfilePlaylist(_:)``.
  public func movePlaylists(
    _ playlistIds: [String],
    from sourceFolderId: String?,
    to destinationFolderId: String?
  ) {
    let validPlaylistIds = playlistIds.filter { !$0.isEmpty }
    guard !validPlaylistIds.isEmpty else { return }
    guard let context = managedObjectContext else { return }
    guard let sourceServerId = resolveServerFolderId(sourceFolderId, in: context),
          let destinationServerId = resolveServerFolderId(destinationFolderId, in: context),
          sourceServerId != destinationServerId
    else { return }

    performBatchedUpdates {
      var nextSortOrder = PlaylistFolderOrdering.appendSortOrder(
        after: siblings(inFolderId: destinationServerId, in: context)
      )
      var movedPlaylistIds = [String]()

      for playlistId in validPlaylistIds {
        guard let playlistMO = fetchPlaylistMO(by: playlistId, in: context) else { continue }
        if let sourcePlacementMO = fetchPlacement(
          playlistId: playlistId, folderId: sourceServerId, in: context
        ) {
          context.delete(sourcePlacementMO)
        }
        let placementMO = fetchPlacement(
          playlistId: playlistId, folderId: destinationServerId, in: context
        ) ?? makePlacementMO(playlist: playlistMO, folderId: destinationServerId, in: context)
        // Keep the selection's own order across the move: consecutive gaps in
        // the order the caller listed them.
        placementMO.sortOrderValue = nextSortOrder
        nextSortOrder += PlaylistFolderOrdering.sortOrderGap
        movedPlaylistIds.append(playlistId)
      }
      try? context.save()

      for playlistId in movedPlaylistIds {
        pushReplaceAllPlacements(playlistId: playlistId, in: context)
      }
      guard !movedPlaylistIds.isEmpty else { return }
      notifyChange()
      exportCurrentTree()
    }
  }

  // MARK: - Moving folders

  /// Re-parent several folders at once. Cycles are refused per folder by
  /// ``moveFolder(id:toParent:)``, so a selection that mixes a legal move with
  /// an illegal one applies the legal part rather than failing wholesale.
  public func moveFolders(_ folderIds: [String], toParent newParentFolderId: String?) {
    guard !folderIds.isEmpty else { return }
    performBatchedUpdates {
      for folderId in folderIds where folderId != newParentFolderId {
        moveFolder(id: folderId, toParent: newParentFolderId)
      }
    }
  }

  // MARK: - Moving a mixed selection

  /// Move a mixed selection of folders and playlists into one destination —
  /// what a drag of several rows onto a folder row, or "Move to Folder…" over a
  /// mixed selection, does.
  public func moveSiblings(
    folderIds: [String],
    playlistIds: [String],
    from sourceFolderId: String?,
    to destinationFolderId: String?
  ) {
    guard !folderIds.isEmpty || !playlistIds.isEmpty else { return }
    performBatchedUpdates {
      moveFolders(folderIds, toParent: destinationFolderId)
      movePlaylists(playlistIds, from: sourceFolderId, to: destinationFolderId)
    }
  }

  // MARK: - Adding without moving

  /// File several playlists into an additional folder, leaving every placement
  /// they already have intact — the "Add to Folder…" action, as against
  /// "Move to Folder…".
  ///
  /// Folders cannot take part: a folder has exactly one parent, so there is no
  /// "also in" for them. Callers pass folder ids only so the two actions can
  /// share a selection; they are skipped here deliberately.
  public func addPlaylistsToAdditionalFolder(
    _ playlistIds: [String],
    folderId: String
  ) {
    addPlaylists(playlistIds, to: folderId)
  }

  // MARK: - New folder from a selection

  /// Create a folder at `parentFolderId` and move the given selection into it.
  ///
  /// - Returns: the new folder, or `nil` when creation failed.
  @discardableResult
  public func createFolder(
    named name: String,
    in parentFolderId: String?,
    movingFolders folderIds: [String],
    playlists playlistIds: [String]
  )
    -> PlaylistFolder? {
    var createdFolder: PlaylistFolder?
    performBatchedUpdates {
      let newFolder = createFolder(name: name, parent: parentFolderId)
      createdFolder = newFolder
      // Folders already inside the selection must not be re-parented into a
      // folder that is itself one of them; `moveFolders` skips the identity
      // case, and the cycle check in `moveFolder` covers the rest.
      moveSiblings(
        folderIds: folderIds,
        playlistIds: playlistIds,
        from: parentFolderId,
        to: newFolder.id
      )
    }
    return createdFolder
  }
}
