//
//  AutoDownloadLibrarySyncer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 13.04.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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
import OSLog

@MainActor
public class AutoDownloadLibrarySyncer {
  private let log = OSLog(subsystem: "Amperfy", category: "AutoDownloadLibrarySyncer")
  private let storage: PersistentStorage
  private let account: Account
  private let librarySyncer: LibrarySyncer
  private let playableDownloadManager: DownloadManageable

  /// Albums already re-verified against the server this app session by the
  /// Recently-Added-surface check in `syncNewestLibraryElements`. Verifying once
  /// per session is enough to heal stale entries while keeping sync traffic flat.
  @MainActor
  private static var verifiedRecentSurfaceAlbumIDs = Set<NSManagedObjectID>()

  public init(
    storage: PersistentStorage,
    account: Account,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable
  ) {
    self.storage = storage
    self.account = account
    self.librarySyncer = librarySyncer
    self.playableDownloadManager = playableDownloadManager
  }

  @MainActor
  public func syncNewestLibraryElements(
    offset: Int = 0,
    count: Int = AmperKit.newestElementsFetchCount
  ) async throws {
    let oldNewestAlbums = Set(storage.main.library.getNewestAlbums(
      for: account,
      offset: 0,
      count: count
    ))
    var newNewestAlbums = Set<Album>()
    var fetchNeededNewestAlbums = Set<Album>()

    try await librarySyncer.syncNewestAlbums(offset: offset, count: count)
    let updatedNewestAlbums = Set(storage.main.library.getNewestAlbums(
      for: account,
      offset: 0,
      count: count
    ))
    newNewestAlbums = updatedNewestAlbums.subtracting(oldNewestAlbums)
    if offset == 0 {
      if newNewestAlbums.isEmpty {
        os_log("No new albums", log: self.log, type: .info)
      } else {
        os_log("%i new albums", log: self.log, type: .info, newNewestAlbums.count)
      }
    }

    // Re-sync songs for every album in the newest window that needs it — not just the
    // newly appeared ones. SsAlbumParserDelegate clears isSongsMetaDataSynced when the
    // server-side songCount changed, so this is what prunes server-deleted songs from
    // albums that are still present (Recently Added accuracy).
    fetchNeededNewestAlbums = updatedNewestAlbums.filter { !$0.isSongsMetaDataSynced }
    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      for album in fetchNeededNewestAlbums {
        taskGroup.addTask { @MainActor @Sendable in
          try await self.librarySyncer.sync(album: album)
        }
      }
      try await taskGroup.waitForAll()
    }

    // Albums that were in the local newest window but are gone after the server sync
    // either fell out of the window naturally or were deleted server-side. Verify each
    // one: sync(album:) marks a server-deleted album (and its songs) as remote deleted
    // via its not-available handling. Errors are expected here (the "no longer
    // available" report) and must not abort the rest of the sync.
    let vanishedNewestAlbums = oldNewestAlbums.subtracting(updatedNewestAlbums)
    for album in vanishedNewestAlbums {
      do {
        try await librarySyncer.sync(album: album)
      } catch {
        os_log(
          "Newest album <%s> could not be verified (likely deleted on server): %s",
          log: log,
          type: .info,
          album.name,
          error.localizedDescription
        )
      }
    }

    // Recently-Added-surface verification: a song deleted server-side while this
    // client wasn't watching (or before this fix shipped) keeps its original
    // addedDate and sorts to the top of Recently Added forever. Re-verify the
    // albums backing the most recently added, still-visible songs whenever the
    // server's current newest window doesn't vouch for them — sync(album:) either
    // refreshes their song set (pruning server-deleted songs) or marks a fully
    // deleted album (and its songs) as remote deleted. Throttled to once per album
    // per app session; for a healthy library the newest window vouches for these
    // albums and this loop does nothing.
    if offset == 0 {
      let recentSurfaceFetch: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
      recentSurfaceFetch.fetchLimit = count
      recentSurfaceFetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        storage.main.library.getFetchPredicate(forAccount: account),
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      ])
      let recentSurfaceSongs = (try? storage.main.context.fetch(recentSurfaceFetch)) ?? []
      let recentSurfaceAlbums = Set(recentSurfaceSongs.compactMap { $0.album })
        .map { Album(managedObject: $0) }
      let albumsToVerify = recentSurfaceAlbums.filter { album in
        album.remoteStatus == .available &&
          !updatedNewestAlbums.contains(album) &&
          !Self.verifiedRecentSurfaceAlbumIDs.contains(album.managedObject.objectID)
      }
      os_log(
        "Recently-added surface: %i songs, %i backing albums, %i to verify",
        log: log,
        type: .info,
        recentSurfaceSongs.count,
        recentSurfaceAlbums.count,
        albumsToVerify.count
      )
      for album in albumsToVerify {
        // Two overlapping sync passes (background + Home) can snapshot the same
        // candidate list before either starts verifying — re-check at loop time.
        guard !Self.verifiedRecentSurfaceAlbumIDs.contains(album.managedObject.objectID)
        else { continue }
        Self.verifiedRecentSurfaceAlbumIDs.insert(album.managedObject.objectID)
        os_log(
          "Recently-added surface: verifying album <%s>",
          log: log,
          type: .info,
          album.name
        )
        do {
          try await librarySyncer.sync(album: album)
        } catch {
          os_log(
            "Recently-added album <%s> could not be verified (likely deleted on server): %s",
            log: log,
            type: .info,
            album.name,
            error.localizedDescription
          )
        }
      }
    }

    if offset == 0, !oldNewestAlbums.isEmpty, !newNewestAlbums.isEmpty,
       storage.settings.accounts.getSetting(account.info).read.isAutoDownloadLatestSongsActive {
      var newestSongs = [AbstractPlayable]()
      for album in newNewestAlbums {
        newestSongs.append(contentsOf: album.songs)
      }
      playableDownloadManager.download(objects: newestSongs)
    }
  }

  /// return: new synced podcast episodes if an initial sync already occued. If this is the initial sync no episods are returned
  @MainActor
  public func syncNewestPodcastEpisodes() async throws -> [PodcastEpisode] {
    let oldNewestEpisodes = Set(storage.main.library.getNewestPodcastEpisode(
      for: account,
      count: 20
    ))
    try await librarySyncer.syncNewestPodcastEpisodes()

    let updatedEpisodes = Set(storage.main.library.getNewestPodcastEpisode(for: account, count: 20))
    let newAddedNewestEpisodes = updatedEpisodes.subtracting(oldNewestEpisodes)
    if !oldNewestEpisodes.isEmpty, !newAddedNewestEpisodes.isEmpty,
       storage.settings.accounts.getSetting(account.info).read
       .isAutoDownloadLatestPodcastEpisodesActive {
      playableDownloadManager.download(objects: Array(newAddedNewestEpisodes))
    }
    if !oldNewestEpisodes.isEmpty {
      return Array(newAddedNewestEpisodes)
    } else {
      return [PodcastEpisode]()
    }
  }
}
