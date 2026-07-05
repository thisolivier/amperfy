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
