//
//  PlaylistMO+CoreDataClass.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 30.12.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

// MARK: - PlaylistMO

@objc(PlaylistMO)
public final class PlaylistMO: NSManagedObject {
  /// Backstop only. `songCount` is kept in step eagerly by the `Playlist`
  /// mutators (see `Playlist.refreshSongCount`), because `willSave` runs too
  /// late to be the only writer: `save()` opens by calling
  /// `processPendingChanges`, which posts `objectsDidChange` — so every
  /// fetched-results controller, and every header refreshed off one, read the
  /// count BEFORE this ran and therefore saw the previous save's value.
  ///
  /// This stays as a safety net for any path that mutates `items` through the
  /// managed object directly (the XML parser delegates do).
  override public func willSave() {
    super.willSave()
    if hasChangedSongs {
      refreshSongCount()
    }
  }

  fileprivate var hasChangedSongs: Bool {
    changedValues().keys.contains(#keyPath(items))
  }

  /// Recompute the denormalised count from the rows. Cheap and idempotent.
  ///
  /// The denormalisation is deliberate — `Playlist.songCount` must not fault a
  /// playlist's `items` relationship just to render a row in a list of
  /// hundreds of playlists — so the cure for staleness is to write it at every
  /// mutation rather than to compute it on read.
  func refreshSongCount() {
    guard Int16(clamping: items.count) != songCount else { return }
    songCount = Int16(clamping: items.count)
  }

  public func removeAllItems() {
    let mutableItems = mutableOrderedSetValue(forKeyPath: #keyPath(items))
    mutableItems.removeAllObjects()
  }

  public func moveInsideItems(fromIndex: Int, to: Int) {
    let fromItem = items[fromIndex]
    removeFromItems(at: fromIndex)
    insertIntoItems(fromItem, at: to)
  }

  static var excludeSystemPlaylistsFetchPredicate: NSPredicate {
    NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "%K == nil", #keyPath(PlaylistMO.playersContextPlaylist)),
      NSPredicate(format: "%K == nil", #keyPath(PlaylistMO.playersShuffledContextPlaylist)),
      NSPredicate(format: "%K == nil", #keyPath(PlaylistMO.playersUserQueuePlaylist)),
      NSPredicate(format: "%K == nil", #keyPath(PlaylistMO.playersPodcastPlaylist)),
    ])
  }

  static var alphabeticSortedFetchRequest: NSFetchRequest<PlaylistMO> {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.alphabeticSectionInitial),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: "id",
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var lastPlayedDateFetchRequest: NSFetchRequest<PlaylistMO> {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(PlaylistMO.lastPlayedDate), ascending: false),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.name),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var lastChangedDateFetchRequest: NSFetchRequest<PlaylistMO> {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(PlaylistMO.changeDate), ascending: false),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.name),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var durationFetchRequest: NSFetchRequest<PlaylistMO> {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(PlaylistMO.duration), ascending: false),
      NSSortDescriptor(key: #keyPath(PlaylistMO.songCount), ascending: false),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.name),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }
}

// MARK: CoreDataIdentifyable

extension PlaylistMO: CoreDataIdentifyable {
  static var identifierKey: KeyPath<PlaylistMO, String?> {
    \PlaylistMO.name
  }

  func passOwnership(to targetPlaylist: PlaylistMO) {}
}
