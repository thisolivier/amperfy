//
//  CoreDataPlaylistProvider.swift
//  AmperfyKit
//
//  Bridges Core Data playlist/song data to the PlaylistDataProvider
//  protocol, isolating the computation engine from Core Data.
//
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

/// Must be called from the context's queue (e.g., inside performAndWait).
public final class CoreDataPlaylistProvider: PlaylistDataProvider {
  private let context: NSManagedObjectContext
  private var cachedPlaylistObjectIDs: [NSManagedObjectID]?

  public init(context: NSManagedObjectContext) {
    self.context = context
  }

  public func fetchPlaylistBatch(offset: Int, limit: Int) -> [PlaylistDescriptor] {
    let objectIDs = ensurePlaylistObjectIDs()
    let endIndex = min(offset + limit, objectIDs.count)
    guard offset < endIndex else { return [] }

    let batchObjectIDs = Array(objectIDs[offset ..< endIndex])
    var descriptors: [PlaylistDescriptor] = []

    for objectID in batchObjectIDs {
      guard let playlistMO = try? context.existingObject(with: objectID) as? PlaylistMO
      else { continue }

      let songIds = extractDeduplicatedSongIds(from: playlistMO)
      guard songIds.count >= 2 else { continue }

      descriptors.append(PlaylistDescriptor(
        playlistId: playlistMO.id,
        songIds: songIds
      ))
    }

    // Release faulted objects to limit memory
    context.reset()
    return descriptors
  }

  public func songsByAlbum(for songIds: Set<String>) -> [String: [String]] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(
      format: "%K IN %@ AND %K != nil",
      #keyPath(SongMO.id),
      songIds,
      #keyPath(SongMO.album)
    )

    guard let songs = try? context.fetch(fetchRequest) else { return [:] }

    var albumGroups: [String: [String]] = [:]
    for songMO in songs {
      guard let albumMO = songMO.album else { continue }
      albumGroups[albumMO.id, default: []].append(songMO.id)
    }

    context.reset()

    // Only return albums with 2+ songs
    return albumGroups.filter { $0.value.count >= 2 }
  }

  // MARK: - Private

  private func ensurePlaylistObjectIDs() -> [NSManagedObjectID] {
    if let cached = cachedPlaylistObjectIDs {
      return cached
    }

    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()

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
    let notPlayerContextPredicate = NSPredicate(
      format: "%K == nil", #keyPath(PlaylistMO.playersContextPlaylist)
    )
    let notPlayerShuffledPredicate = NSPredicate(
      format: "%K == nil", #keyPath(PlaylistMO.playersShuffledContextPlaylist)
    )
    let notPlayerQueuePredicate = NSPredicate(
      format: "%K == nil", #keyPath(PlaylistMO.playersUserQueuePlaylist)
    )
    let notPodcastPredicate = NSPredicate(
      format: "%K == nil", #keyPath(PlaylistMO.playersPodcastPlaylist)
    )

    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [
        notSmartPredicate,
        hasNamePredicate,
        notPlayerContextPredicate,
        notPlayerShuffledPredicate,
        notPlayerQueuePredicate,
        notPodcastPredicate,
      ]
    )

    let playlists = (try? context.fetch(fetchRequest)) ?? []
    let objectIDs = playlists.map { $0.objectID }

    cachedPlaylistObjectIDs = objectIDs
    return objectIDs
  }

  private func extractDeduplicatedSongIds(from playlist: PlaylistMO) -> [String] {
    var seenIds = Set<String>()
    var songIds: [String] = []
    for item in playlist.items {
      guard item.playable is SongMO else { continue }
      let songId = item.playable.id
      if seenIds.insert(songId).inserted {
        songIds.append(songId)
      }
    }
    return songIds
  }
}
