//
//  PlaylistItemCellResolver.swift
//  Amperfy
//
//  Created for AMP-28 — blank rows after a playlist add.
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

import AmperfyKit
import CoreData
import OSLog
import UIKit

/// Resolves a diffable snapshot's `NSManagedObjectID` back to the playlist item
/// it identifies, falling back to the fetched-results controller when the ID
/// itself has gone stale.
///
/// The real cure for the blank-rows bug is upstream, in
/// `LibraryStorage.saveContext()`: permanent object IDs are now assigned before
/// the save, so the FRC never publishes a snapshot keyed on an identity that is
/// about to be replaced. This is the belt to that braces.
///
/// It exists because the old failure mode was so much worse than it needed to
/// be. When `existingObject(with:)` threw, the cell providers returned a bare
/// `UITableViewCell()` — which is not an error state the user can read, it is a
/// row with separators and nothing in it. The table knew the row's position
/// perfectly well; only the identity lookup had failed. So resolve by position
/// instead, and the row renders correctly even if some future change
/// reintroduces a stale identifier.
@MainActor
enum PlaylistItemCellResolver {
  private static let logger = Logger(subsystem: "Amperfy", category: "PlaylistItemCellResolver")

  /// The playlist item for `objectID`, or — if that identity no longer resolves
  /// — the item the fetched-results controller holds at `indexPath`.
  ///
  /// Returns `nil` only when both routes fail, which means the row genuinely
  /// has no backing object and an empty cell is the honest answer.
  static func resolvePlaylistItem(
    forObjectID objectID: NSManagedObjectID,
    in library: LibraryStorage,
    context: NSManagedObjectContext,
    fetchedResultsController: PlaylistItemsFetchedResultsController?,
    indexPath: IndexPath
  )
    -> PlaylistItem? {
    if let object = try? context.existingObject(with: objectID),
       let playlistItemMO = object as? PlaylistItemMO {
      return PlaylistItem(library: library, managedObject: playlistItemMO)
    }

    guard let fetchedResultsController,
          isWithinBounds(indexPath: indexPath, of: fetchedResultsController)
    else {
      logger.error(
        """
        A playlist row's object ID no longer resolves and its position is out of \
        range; rendering an empty cell.
        """
      )
      return nil
    }

    logger.notice(
      """
      A playlist row's object ID no longer resolves; falling back to the fetched \
      item at its position so the row is not rendered blank.
      """
    )
    return fetchedResultsController.getWrappedEntity(at: indexPath)
  }

  /// `getWrappedEntity(at:)` goes through `NSFetchedResultsController.object(at:)`,
  /// which traps rather than returning nil, so the bounds are checked here.
  private static func isWithinBounds(
    indexPath: IndexPath,
    of fetchedResultsController: PlaylistItemsFetchedResultsController
  )
    -> Bool {
    let sections = fetchedResultsController.fetchResultsController.sections ?? []
    guard indexPath.section >= 0, indexPath.section < sections.count else { return false }
    return indexPath.row >= 0 && indexPath.row < sections[indexPath.section].numberOfObjects
  }
}
