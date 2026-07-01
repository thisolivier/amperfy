//
//  HomeManager.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 29.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

// MARK: - HomeItem

struct HomeItem: Hashable, @unchecked Sendable {
  let id = UUID()
  var playableContainable: PlayableContainable

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - HomeManager

@MainActor
class HomeManager: NSObject {
  public static let sectionMaxItemCount = 20
  /// The number of recent-track rows the home widget shows when present.
  /// Once the widget is on the home screen it always renders, always
  /// showing the 10 most recently-added qualifying tracks (or the whole
  /// library if it has fewer than 10) — see `RecentTracksQuery.topN`.
  public static let recentTracksWidgetItemCount = 10

  public var orderedVisibleSections: [HomeSection]
  public var data: [HomeSection: [HomeItem]] = [:]
  /// Count of additional recent-tracks (beyond the 7 visible widget rows)
  /// added in the last 7 days. Used by HomeVC to render the section
  /// footer / header subtitle. Refreshed alongside `data[.recentTracks]`.
  public var recentTracksExtraCount: Int = 0
  public var applySnapshotCB: VoidFunctionCallback?

  private let account: Account
  private let storage: PersistentStorage
  private let getMeta: (_ accountInfo: AccountInfo) -> MetaManager
  private let eventLogger: EventLogger

  var isOfflineMode: Bool {
    storage.settings.user.isOfflineMode
  }

  private var albumsRecentlyPlayedFetchController: AlbumFetchedResultsController?
  private var albumsNewestFetchController: AlbumFetchedResultsController?
  private var playlistsLastTimePlayedFetchController: PlaylistFetchedResultsController?
  private var podcastEpisodesFetchedController: PodcastEpisodesReleaseDateFetchedResultsController?
  private var podcastsFetchedController: PodcastFetchedResultsController?
  private var radiosFetchedController: RadiosFetchedResultsController?
  private var favouriteAlbumsFetchController: AlbumFetchedResultsController?
  private var favouriteArtistsFetchController: ArtistFetchedResultsController?
  private var pinnedPlaylistsObserver: NSObjectProtocol?

  init(
    account: Account,
    storage: PersistentStorage,
    getMeta: @escaping (_ accountInfo: AccountInfo) -> MetaManager,
    eventLogger: EventLogger
  ) {
    self.account = account
    self.storage = storage
    self.getMeta = getMeta
    self.eventLogger = eventLogger
    self.orderedVisibleSections = storage.settings.accounts
      .getSetting(account.info).read.homeSections
  }

  func createFetchController() {
    if orderedVisibleSections.contains(where: { $0 == .recentlyPlayedAlbums }) {
      albumsRecentlyPlayedFetchController = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .recent,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      albumsRecentlyPlayedFetchController?.delegate = self
      albumsRecentlyPlayedFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .recent
      )
      updateAlbumsRecentlyPlayed()
    } else {
      albumsRecentlyPlayedFetchController?.delegate = nil
      albumsRecentlyPlayedFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .newestAlbums }) {
      // Home tab newest-albums section always filters to whole albums
      // (singles / bags of singles are hidden). Threshold 3 matches the
      // library-wide setting. See `spike/amperfy/BACKLOG.md` §2.2.
      albumsNewestFetchController = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .newest,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount,
        wholeAlbumsOnly: true,
        wholeAlbumMinSongCount: 3
      )
      albumsNewestFetchController?.delegate = self
      albumsNewestFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .newest
      )
      updateAlbumsNewest()
    } else {
      albumsNewestFetchController?.delegate = nil
      albumsNewestFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .randomAlbums }) {
      Task { @MainActor in
        await updateRandomAlbums(isOfflineMode: isOfflineMode)
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomArtists }) {
      Task { @MainActor in
        await updateRandomArtists(isOfflineMode: isOfflineMode)
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomGenres }) {
      Task { @MainActor in
        await updateRandomGenres()
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomSongs }) {
      Task { @MainActor in
        await updateRandomSongs(isOfflineMode: isOfflineMode)
      }
    }

    if orderedVisibleSections.contains(where: { $0 == .lastTimePlayedPlaylists }) {
      playlistsLastTimePlayedFetchController = PlaylistFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .lastPlayed,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      playlistsLastTimePlayedFetchController?.delegate = self
      playlistsLastTimePlayedFetchController?.search(
        searchText: "",
        playlistSearchCategory: isOfflineMode ? .cached : .all
      )
      updatePlaylistsLastTimePlayed()
    } else {
      playlistsLastTimePlayedFetchController?.delegate = nil
      playlistsLastTimePlayedFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .newestPodcastEpisodes }) {
      podcastEpisodesFetchedController = PodcastEpisodesReleaseDateFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      podcastEpisodesFetchedController?.delegate = self
      podcastEpisodesFetchedController?.search(searchText: "", onlyCachedSongs: isOfflineMode)
      updatePodcastEpisodesNewest()
    } else {
      podcastEpisodesFetchedController?.delegate = nil
      podcastEpisodesFetchedController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .podcasts }) {
      podcastsFetchedController = PodcastFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: false
      )
      podcastsFetchedController?.delegate = self
      podcastsFetchedController?.search(searchText: "", onlyCached: isOfflineMode)
      updatePodcasts()
    } else {
      podcastsFetchedController?.delegate = nil
      podcastsFetchedController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .radios }) {
      radiosFetchedController = RadiosFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: true
      )
      radiosFetchedController?.delegate = self
      radiosFetchedController?.fetch()
      updateRadios()
    } else {
      radiosFetchedController?.delegate = nil
      radiosFetchedController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .recentTracks }) {
      // Recent-tracks widget: pure-fetch, no FRC. The widget is a polled
      // snapshot — we re-run the query on createFetchController() and on
      // each viewIsAppearing via updateFromRemote(). See BACKLOG.md §3.1.
      updateRecentTracks()
    }

    if orderedVisibleSections.contains(where: { $0 == .favouriteAlbums }) {
      // Favourite albums: isFavorite == YES, no whole-album filter (D.4b).
      favouriteAlbumsFetchController = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .name,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      favouriteAlbumsFetchController?.delegate = self
      favouriteAlbumsFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .favorites
      )
      updateFavouriteAlbums()
    } else {
      favouriteAlbumsFetchController?.delegate = nil
      favouriteAlbumsFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .favouriteArtists }) {
      favouriteArtistsFetchController = ArtistFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .name,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      favouriteArtistsFetchController?.delegate = self
      favouriteArtistsFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .favorites
      )
      updateFavouriteArtists()
    } else {
      favouriteArtistsFetchController?.delegate = nil
      favouriteArtistsFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .favouritePlaylists }) {
      // Pinned playlists: UserDefaults-backed, not FRC. Subscribe to
      // PinnedPlaylistStore.didChangeNotification for live updates.
      if pinnedPlaylistsObserver == nil {
        pinnedPlaylistsObserver = NotificationCenter.default.addObserver(
          forName: PinnedPlaylistStore.didChangeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.updateFavouritePlaylists()
        }
      }
      updateFavouritePlaylists()
    } else {
      if let observer = pinnedPlaylistsObserver {
        NotificationCenter.default.removeObserver(observer)
        pinnedPlaylistsObserver = nil
      }
    }
  }

  func updateFromRemote() {
    guard storage.settings.user.isOnlineMode else { return }
    if orderedVisibleSections.contains(where: { $0 == .newestAlbums }) {
      Task { @MainActor in
        do {
          try await AutoDownloadLibrarySyncer(
            storage: self.storage,
            account: self.account,
            librarySyncer: self.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.getMeta(self.account.info)
              .playableDownloadManager
          )
          .syncNewestLibraryElements(offset: 0, count: Self.sectionMaxItemCount)
        } catch {
          self.eventLogger.report(topic: "Newest Albums Sync", error: error)
        }
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .recentlyPlayedAlbums }) {
      Task { @MainActor in
        do {
          try await self.getMeta(self.account.info).librarySyncer
            .syncRecentAlbums(
              offset: 0,
              count: Self.sectionMaxItemCount
            )
        } catch {
          self.eventLogger.report(topic: "Recent Albums Sync", error: error)
        }
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .lastTimePlayedPlaylists }) {
      Task { @MainActor in do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.eventLogger.report(topic: "Playlists Sync", error: error)
      }}
    }
    if orderedVisibleSections.contains(where: { $0 == .newestPodcastEpisodes }) {
      Task { @MainActor in do {
        let _ = try await AutoDownloadLibrarySyncer(
          storage: self.storage,
          account: self.account,
          librarySyncer: self.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.getMeta(self.account.info)
            .playableDownloadManager
        )
        .syncNewestPodcastEpisodes()
      } catch {
        self.eventLogger.report(topic: "Podcasts Sync", error: error)
      }}
    }
    if orderedVisibleSections.contains(where: { $0 == .radios }) {
      Task { @MainActor in
        do {
          try await self.getMeta(self.account.info).librarySyncer
            .syncRadios()
        } catch {
          self.eventLogger.report(topic: "Radios Sync", error: error)
        }
      }
    }
  }

  func updateAlbumsRecentlyPlayed() {
    if let albums = albumsRecentlyPlayedFetchController?.fetchedObjects as? [AlbumMO] {
      data[.recentlyPlayedAlbums] = albums.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateAlbumsNewest() {
    if let albums = albumsNewestFetchController?.fetchedObjects as? [AlbumMO] {
      data[.newestAlbums] = albums.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateRandomAlbums(isOfflineMode: Bool) async {
    let randomAlbums = storage.main.library.getRandomWholeAlbums(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomAlbums] = randomAlbums.compactMap {
      HomeItem(playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomArtists(isOfflineMode: Bool) async {
    let randomArtists = storage.main.library.getRandomArtists(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomArtists] = randomArtists.compactMap {
      HomeItem(playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomGenres() async {
    let randomGenres = storage.main.library.getRandomGenres(
      for: account,
      count: Self.sectionMaxItemCount
    )
    data[.randomGenres] = randomGenres.compactMap {
      HomeItem(playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomSongs(isOfflineMode: Bool) async {
    let randomSongs = storage.main.library.getRandomSongs(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomSongs] = randomSongs.compactMap {
      HomeItem(playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updatePlaylistsLastTimePlayed() {
    if let playlists = playlistsLastTimePlayedFetchController?.fetchedObjects as? [PlaylistMO] {
      data[.lastTimePlayedPlaylists] = playlists.prefix(Self.sectionMaxItemCount)
        .compactMap { Playlist(
          library: storage.main.library,
          managedObject: $0
        ) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updatePodcastEpisodesNewest() {
    if let podcastEpisodes = podcastEpisodesFetchedController?
      .fetchedObjects as? [PodcastEpisodeMO] {
      data[.newestPodcastEpisodes] = podcastEpisodes.prefix(Self.sectionMaxItemCount)
        .compactMap { PodcastEpisode(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updatePodcasts() {
    if let podcasts = podcastsFetchedController?.fetchedObjects as? [PodcastMO] {
      data[.podcasts] = podcasts.prefix(Self.sectionMaxItemCount)
        .compactMap { Podcast(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateRadios() {
    if let radios = radiosFetchedController?.fetchedObjects as? [RadioMO] {
      data[.radios] = radios.prefix(Self.sectionMaxItemCount)
        .compactMap { Radio(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateFavouriteAlbums() {
    if let albums = favouriteAlbumsFetchController?.fetchedObjects as? [AlbumMO] {
      data[.favouriteAlbums] = albums.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateFavouriteArtists() {
    if let artists = favouriteArtistsFetchController?.fetchedObjects as? [ArtistMO] {
      data[.favouriteArtists] = artists.prefix(Self.sectionMaxItemCount)
        .compactMap { Artist(managedObject: $0) }.compactMap {
          HomeItem(playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateFavouritePlaylists() {
    let pinnedIds = PinnedPlaylistStore.shared.pinnedIds
    guard !pinnedIds.isEmpty else {
      data[.favouritePlaylists] = []
      applySnapshotCB?()
      return
    }
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "%K IN %@", #keyPath(PlaylistMO.id), pinnedIds)
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(
        key: #keyPath(PlaylistMO.name), ascending: true,
        selector: #selector(NSString.caseInsensitiveCompare(_:))
      ),
    ]
    let context = storage.main.context
    do {
      let playlistMOs = try context.fetch(fetchRequest)
      data[.favouritePlaylists] = playlistMOs.prefix(Self.sectionMaxItemCount)
        .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
        .compactMap { HomeItem(playableContainable: $0) }
    } catch {
      data[.favouritePlaylists] = []
    }
    applySnapshotCB?()
  }

  /// Refresh the recent-tracks widget data. Uses `RecentTracksQuery`'s
  /// two-stage fetch (`widgetTracks(context:minimumCount:)`) so the widget
  /// always renders: stage 1 supplies the top songs that pass the
  /// non-whole-album filter (threshold 5), and stage 2 pads the remainder
  /// with the most-recently-added songs of ANY album type (deduped against
  /// stage 1) whenever stage 1 alone falls short of
  /// `recentTracksWidgetItemCount` — including the case where a library's
  /// recent additions are entirely whole albums and stage 1 returns zero
  /// rows. Also computes the "X more in the last 7 days" footer count.
  func updateRecentTracks() {
    let context = storage.main.context
    let topSongs = RecentTracksQuery.widgetTracks(
      context: context,
      minimumCount: Self.recentTracksWidgetItemCount
    )
    data[.recentTracks] = topSongs.compactMap { Song(managedObject: $0) }.compactMap {
      HomeItem(playableContainable: $0)
    }
    let lastWeekCount = RecentTracksQuery.lastMDaysCount(context: context, m: 7)
    // Subtract the visible rows that are themselves in the 7-day window so
    // the footer reads "X more" rather than double-counting.
    let visibleFreshCount = topSongs.filter { song in
      guard let added = song.addedDate else { return false }
      return added >= Date().addingTimeInterval(-7 * 24 * 60 * 60)
    }.count
    recentTracksExtraCount = max(0, lastWeekCount - visibleFreshCount)
    applySnapshotCB?()
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controller is created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      if controller == albumsRecentlyPlayedFetchController?.fetchResultsController {
        updateAlbumsRecentlyPlayed()
      } else if controller == albumsNewestFetchController?.fetchResultsController {
        updateAlbumsNewest()
      } else if controller == playlistsLastTimePlayedFetchController?.fetchResultsController {
        updatePlaylistsLastTimePlayed()
      } else if controller == podcastEpisodesFetchedController?.fetchResultsController {
        updatePodcastEpisodesNewest()
      } else if controller == podcastsFetchedController?.fetchResultsController {
        updatePodcasts()
      } else if controller == radiosFetchedController?.fetchResultsController {
        updateRadios()
      } else if controller == favouriteAlbumsFetchController?.fetchResultsController {
        updateFavouriteAlbums()
      } else if controller == favouriteArtistsFetchController?.fetchResultsController {
        updateFavouriteArtists()
      }
    }
  }
}
