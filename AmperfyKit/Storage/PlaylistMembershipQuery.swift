//
//  PlaylistMembershipQuery.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (Feature C — Show playlists).
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

/// Answers "which user playlists contain this song?" — the backing query
/// for the song `...` menu's "Show playlists" action (Feature C).
///
/// Fires on-demand when the menu item is tapped. Results are not cached;
/// the caller invokes this once per tap and throws the array away after
/// presenting the list VC. Smart playlists are excluded because they are
/// derived rules, not membership lists, and showing them would misleadingly
/// imply the user added the song to them.
public enum PlaylistMembershipQuery {
  /// Returns every non-smart `PlaylistMO` that contains at least one
  /// `PlaylistItemMO` whose underlying playable matches `songId`, sorted
  /// by name ascending (case-insensitive).
  ///
  /// - Parameters:
  ///   - songId: The canonical song id (`AbstractPlayableMO.id`) to search
  ///     for. This is the same id used across the storage layer, so both
  ///     server-synced and locally-wrapped songs resolve correctly.
  ///   - context: The managed object context to fetch against. In prod this
  ///     is `appDelegate.storage.main.context`; tests pass the in-memory
  ///     `testContext` from `CoreDataHelper`.
  ///
  /// The predicate uses the traversal `ANY items.playable.id == songId`
  /// rather than a SUBQUERY because the `items → playable` relationship
  /// is simple enough that Core Data flattens this into a single JOIN.
  ///
  /// Smart playlists are excluded via the canonical
  /// `NOT (id BEGINSWITH Playlist.smartPlaylistIdPrefix)` idiom — the same
  /// form used by `LibraryStorage.getFetchPredicate(forPlaylistSearchCategory: .userOnly)`.
  /// This has to be a prefix check on the stored `id` attribute because
  /// `Playlist.isSmartPlaylist` is a computed Swift property derived from
  /// that prefix, not a persisted Core Data attribute.
  public static func playlistsContaining(
    songId: String,
    in context: NSManagedObjectContext
  )
    -> [PlaylistMO] {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    let membershipPredicate = NSPredicate(
      format: "ANY items.playable.id == %@",
      songId
    )
    let notSmartPredicate = NSPredicate(
      format: "NOT (%K BEGINSWITH %@)",
      #keyPath(PlaylistMO.id),
      Playlist.smartPlaylistIdPrefix
    )
    let hasNamePredicate = NSPredicate(
      format: "%K != nil AND %K != %@",
      #keyPath(PlaylistMO.name),
      #keyPath(PlaylistMO.name),
      ""
    )
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [membershipPredicate, notSmartPredicate, hasNamePredicate]
    )
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.name),
        ascending: true,
        selector: #selector(NSString.caseInsensitiveCompare(_:))
      ),
    ]
    do {
      return try context.fetch(fetchRequest)
    } catch {
      return []
    }
  }
}
