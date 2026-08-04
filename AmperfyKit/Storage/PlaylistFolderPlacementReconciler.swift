//
//  PlaylistFolderPlacementReconciler.swift
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

import Foundation

// MARK: - PlaylistFolderRootId

/// The server spells "at the root" as an empty `folderId`, and accepts the
/// literal `"root"` as a synonym on write. Both normalize to the empty string
/// locally so root placements are ordinary placements rather than a special case.
public enum PlaylistFolderRootId {
  /// Canonical local spelling of the root.
  public static let canonical = ""
  /// Alternative spelling the server also accepts on write paths.
  public static let literal = "root"

  /// Normalize any server or caller spelling of a parent id to the canonical
  /// local form.
  public static func normalized(_ folderId: String?) -> String {
    guard let folderId, !folderId.isEmpty, folderId != literal else { return canonical }
    return folderId
  }

  public static func isRoot(_ folderId: String?) -> Bool {
    normalized(folderId) == canonical
  }
}

// MARK: - ResolvedPlaylistPlacement

/// A placement from the server envelope that has been matched to a playlist this
/// device actually holds.
public struct ResolvedPlaylistPlacement: Sendable, Equatable {
  public let playlistId: String
  /// Normalized: the empty string is the root.
  public let folderId: String
  public let sortOrder: Int?

  public init(playlistId: String, folderId: String, sortOrder: Int?) {
    self.playlistId = playlistId
    self.folderId = folderId
    self.sortOrder = sortOrder
  }
}

// MARK: - PlaylistFolderPlacementResolution

/// The outcome of matching an envelope's `placements` against local state.
public struct PlaylistFolderPlacementResolution: Sendable, Equatable {
  /// Placements that may be written to Core Data as-is.
  public let resolvedPlacements: [ResolvedPlaylistPlacement]
  /// Playlist ids the server filed somewhere but this device does not have.
  /// Reported so sync can log them; never materialized as local rows.
  public let skippedUnknownPlaylistIds: [String]
  /// Folder ids referenced by a placement but absent from the same envelope's
  /// `folders`. A placement into a folder that does not exist cannot be honored.
  public let skippedUnknownFolderIds: [String]

  public init(
    resolvedPlacements: [ResolvedPlaylistPlacement],
    skippedUnknownPlaylistIds: [String],
    skippedUnknownFolderIds: [String]
  ) {
    self.resolvedPlacements = resolvedPlacements
    self.skippedUnknownPlaylistIds = skippedUnknownPlaylistIds
    self.skippedUnknownFolderIds = skippedUnknownFolderIds
  }
}

// MARK: - PlaylistFolderPlacementReconciler

/// Turns the v2 organization envelope's `placements` into the placements this
/// device should hold — pure, so the rules below are testable directly.
///
/// Two rules matter enough to state outright, because both were failure modes of
/// the pre-v2 sync:
///
/// 1. **Never fabricate.** A placement naming a playlist this device does not
///    have is skipped, not turned into a stub playlist. Local playlists arrive
///    through the playlist sync; folder sync only files what already exists.
/// 2. **Absence of placements is not absence of folder.** A folder that appears
///    in `folders` but is named by no placement is simply an *empty folder*. It
///    must survive reconciliation. The old per-folder detail loop conflated
///    "the detail fetch returned nothing" with "empty this folder", which is how
///    memberships evaporated.
public enum PlaylistFolderPlacementReconciler {
  /// Resolve an envelope's placements against the playlists this device holds.
  ///
  /// - Parameters:
  ///   - organization: the capability-confirmed v2 envelope.
  ///   - knownPlaylistIds: ids of playlists present in local storage.
  public static func resolve(
    organization: NavidromeFolderOrganizationResponse,
    knownPlaylistIds: Set<String>
  )
    -> PlaylistFolderPlacementResolution {
    let knownFolderIds = Set(organization.folders.map(\.id))

    var resolvedPlacements = [ResolvedPlaylistPlacement]()
    var skippedUnknownPlaylistIds = [String]()
    var skippedUnknownFolderIds = [String]()
    var seenEdges = Set<String>()

    for placement in organization.placements {
      guard knownPlaylistIds.contains(placement.playlistId) else {
        if !skippedUnknownPlaylistIds.contains(placement.playlistId) {
          skippedUnknownPlaylistIds.append(placement.playlistId)
        }
        continue
      }

      let normalizedFolderId = PlaylistFolderRootId.normalized(placement.folderId)
      if normalizedFolderId != PlaylistFolderRootId.canonical,
         !knownFolderIds.contains(normalizedFolderId) {
        if !skippedUnknownFolderIds.contains(normalizedFolderId) {
          skippedUnknownFolderIds.append(normalizedFolderId)
        }
        continue
      }

      // The contract allows a playlist in several folders, but the same edge
      // twice is meaningless — keep the first and drop repeats.
      let edgeKey = "\(placement.playlistId)\u{1F}\(normalizedFolderId)"
      guard seenEdges.insert(edgeKey).inserted else { continue }

      resolvedPlacements.append(ResolvedPlaylistPlacement(
        playlistId: placement.playlistId,
        folderId: normalizedFolderId,
        sortOrder: placement.sortOrder
      ))
    }

    return PlaylistFolderPlacementResolution(
      resolvedPlacements: resolvedPlacements,
      skippedUnknownPlaylistIds: skippedUnknownPlaylistIds,
      skippedUnknownFolderIds: skippedUnknownFolderIds
    )
  }
}
