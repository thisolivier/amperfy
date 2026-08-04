//
//  PlaylistFolderDropTargetResolver.swift
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

// MARK: - PlaylistFolderDropTarget

/// What a drop onto the browse list means once the row under the pointer, the
/// drop style and the dragged rows are all taken into account.
public enum PlaylistFolderDropTarget: Equatable, Sendable {
  /// Onto a folder row: file the dragged siblings inside that folder.
  case intoFolder(folderId: String)
  /// Between rows: reorder within the current parent, landing at `targetIndex`
  /// in the interleaved sibling list.
  case reorder(targetIndex: Int)
  /// Onto the list background: bring the dragged siblings to the level being
  /// browsed. A no-op for rows that already live here, which is the common case.
  case currentLevel
  /// Nothing sensible to do — most importantly, a folder dropped into itself or
  /// into one of the folders being dragged alongside it.
  case rejected
}

// MARK: - PlaylistFolderDropProposal

/// The drop style UIKit is being asked to preview, expressed without importing
/// UIKit so the resolution stays testable.
public enum PlaylistFolderDropProposal: Sendable, Equatable {
  /// The pointer is over a row and UIKit would drop *into* it.
  case intoRow(rowIndex: Int)
  /// The pointer is between rows and UIKit would insert at `rowIndex`.
  case betweenRows(rowIndex: Int)
  /// The pointer is over empty space below the rows.
  case background
}

// MARK: - PlaylistFolderDropTargetResolver

/// Decides what a drag onto the browse list does.
///
/// Kept apart from the drop delegate because the interesting cases are all
/// arithmetic and set membership — a folder dragged onto itself, a multi-row
/// drag where one of the dragged rows is the folder under the pointer, a
/// reorder index that has to account for rows being lifted out above the drop
/// point — and none of them are worth reproducing by hand on a Mac to check.
public enum PlaylistFolderDropTargetResolver {
  /// Resolve a drop.
  ///
  /// - Parameters:
  ///   - proposal: where UIKit says the pointer is.
  ///   - rowIdentities: the current interleaved row list.
  ///   - draggedIdentities: the rows being dragged. Empty means the drag came
  ///     from outside this list, which this screen does not accept.
  ///   - allowsReordering: `false` while a search or an attribute sort is
  ///     active, because the visible row order is then not the stored sibling
  ///     order and an index would mean nothing. Filing into a folder still
  ///     works — that target is named, not positional.
  public static func resolve(
    proposal: PlaylistFolderDropProposal,
    rowIdentities: [PlaylistFolderBrowseRowIdentity],
    draggedIdentities: [PlaylistFolderBrowseRowIdentity],
    allowsReordering: Bool
  )
    -> PlaylistFolderDropTarget {
    guard !draggedIdentities.isEmpty else { return .rejected }
    let draggedIdentitySet = Set(draggedIdentities)

    switch proposal {
    case let .intoRow(rowIndex):
      guard let rowIdentity = rowIdentities[safeIndex: rowIndex],
            rowIdentity.kind == .folder
      else { return .rejected }
      // Dropping a folder into itself, or into a folder travelling with it, has
      // no meaning and the server would answer 400 on the cycle anyway.
      guard !draggedIdentitySet.contains(rowIdentity) else { return .rejected }
      return .intoFolder(folderId: rowIdentity.id)

    case let .betweenRows(rowIndex):
      guard allowsReordering else { return .rejected }
      let clampedRowIndex = min(max(rowIndex, 0), rowIdentities.count)
      return .reorder(targetIndex: clampedRowIndex)

    case .background:
      return .currentLevel
    }
  }

  /// The sibling index a dragged row should be given so it lands at
  /// `targetRowIndex` *after* the rows being dragged are lifted out.
  ///
  /// Without this, dragging a row downward overshoots: the rows above the drop
  /// point that are themselves part of the drag no longer occupy their old
  /// slots by the time the new sortOrder is applied.
  public static func adjustedInsertionIndex(
    targetRowIndex: Int,
    draggedRowIndices: [Int]
  )
    -> Int {
    let liftedRowsAboveTarget = draggedRowIndices.filter { $0 < targetRowIndex }.count
    return max(targetRowIndex - liftedRowsAboveTarget, 0)
  }

  /// Split a set of dragged rows into the two kinds the store writes through
  /// different endpoints.
  public static func partition(
    _ identities: [PlaylistFolderBrowseRowIdentity]
  )
    -> (folderIds: [String], playlistIds: [String]) {
    var folderIds = [String]()
    var playlistIds = [String]()
    for identity in identities {
      switch identity.kind {
      case .folder: folderIds.append(identity.id)
      case .playlist: playlistIds.append(identity.id)
      }
    }
    return (folderIds: folderIds, playlistIds: playlistIds)
  }
}

// MARK: - Array bounds helper

extension Array {
  fileprivate subscript(safeIndex index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
