//
//  SmartPlaylistRefresher.swift
//  AmperfyKit
//
//  Orchestrates one explicit smart playlist refresh: targeted newest-albums
//  backfill, unsynced-playlist drain, evaluate, persist (V1 spec, 2026-08-17).
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
import os.log

// MARK: - SmartPlaylistRefreshPhase

/// Coarse progress signal for the refresh button's spinner / status line.
/// Deliberately coarse: the UI shows one line of text, not a progress bar per
/// network call.
public enum SmartPlaylistRefreshPhase: Equatable, Sendable {
  /// Paging the full album listing to relearn server-side album track counts,
  /// which is what makes the gained-songs scan able to see anything at all.
  case refreshingAlbumTrackCounts(albumsScanned: Int)
  /// Syncing album songs so song-level `addedDate` exists to filter on — both
  /// the newest-albums walk and the local gained-songs scan report here.
  case backfillingRecentSongs(albumsProcessed: Int, albumsCap: Int)
  /// Fetching items for playlists that only have metadata locally.
  case syncingPlaylists(done: Int, total: Int)
  /// Running the Core Data fetch.
  case evaluating
  /// Result persisted; the outcome is being returned.
  case finished

  public var displayText: String {
    switch self {
    case let .refreshingAlbumTrackCounts(albumsScanned):
      return "Checking album track counts (\(albumsScanned))…"
    case let .backfillingRecentSongs(albumsProcessed, _):
      return "Checking for new songs (\(albumsProcessed))…"
    case let .syncingPlaylists(done, total):
      return "Syncing playlists (\(done)/\(total))…"
    case .evaluating:
      return "Running query…"
    case .finished:
      return "Done"
    }
  }
}

// MARK: - SmartPlaylistRefreshOutcome

/// The result of one refresh, everything the results screen needs to render
/// itself and its caveats.
public struct SmartPlaylistRefreshOutcome {
  /// The state that was persisted (and is now the current smart playlist).
  public let state: SmartPlaylistState
  /// The songs matching the query, in result order — handed straight to the
  /// table so the caller need not re-resolve the frozen ids it just produced.
  public let songs: [SongMO]
  /// `true` when the refresh skipped both sync steps because the app is
  /// offline. The result is still valid, just possibly stale.
  public let wasOfflineRefresh: Bool
  /// `true` when playlist rules were evaluated while some playlists still had
  /// no local items — the membership answer may be incomplete. Only ever true
  /// on an offline refresh (an online refresh drains the unsynced set first).
  public let hasIncompletePlaylistData: Bool
  /// Rules dropped because their playlist no longer exists.
  public let droppedPlaylistRules: [SmartPlaylistRule]
  /// How many albums the backfill actually touched (0 when it was skipped).
  public let albumsBackfilled: Int

  public init(
    state: SmartPlaylistState,
    songs: [SongMO],
    wasOfflineRefresh: Bool,
    hasIncompletePlaylistData: Bool,
    droppedPlaylistRules: [SmartPlaylistRule],
    albumsBackfilled: Int
  ) {
    self.state = state
    self.songs = songs
    self.wasOfflineRefresh = wasOfflineRefresh
    self.hasIncompletePlaylistData = hasIncompletePlaylistData
    self.droppedPlaylistRules = droppedPlaylistRules
    self.albumsBackfilled = albumsBackfilled
  }
}

// MARK: - SmartPlaylistRefresher

/// Runs the one and only path that ever regenerates a smart playlist result.
///
/// Ordering matters and is not negotiable:
///
///  1. **Album track-count refresh** (online, and only when the query has an
///     `addedWithinDays` rule). Pages the full album listing so every album's
///     server-reported `remoteSongCount` is CURRENT — see
///     `refreshAlbumTrackCounts`. Without it the backfill's pass 2 compares
///     against counts that may be months stale and finds nothing.
///  2. **Recent-songs backfill** (same guard). `addedDate` is populated
///     exclusively by song-level XML; the bulk album sync never sets it (see
///     `ADDED_DATE_INVESTIGATION.md`). Two passes, both stopped by SONG-level
///     dates and sharing one album budget — see `backfillRecentSongs`.
///  3. **Playlist item drain** (online, and only when the query has a playlist
///     rule). `PlaylistItemMO` rows exist only for individually fetched
///     playlists, so membership rules would otherwise answer from thin air.
///     Same unsynced-set idiom as `PlaylistSyncWorker`.
///  4. **Evaluate** — one compound fetch.
///  5. **Persist** the frozen result.
///
/// Offline, steps 1 to 3 are skipped and the result is flagged
/// `wasOfflineRefresh`, plus `hasIncompletePlaylistData` when the tracker still
/// reports unsynced playlists and the query depends on membership.
///
/// `@MainActor` throughout, matching `PlaylistSyncWorker`'s main-context model:
/// every `LibrarySyncer` entry point is `@MainActor`, and the managed objects
/// we touch belong to the main context.
@MainActor
public final class SmartPlaylistRefresher {
  /// Hard caps on the targeted backfill (spec §"addedDate sparsity"). A refresh
  /// is a user-visible, spinner-blocking operation; it must be bounded even for
  /// an absurd "added in the last 3650 days" query.
  public static let maxBackfillAlbums = 500
  public static let maxBackfillPages = 10
  public static let backfillPageSize = 50

  /// Caps on the album track-count refresh. 500 is the Subsonic maximum for
  /// `getAlbumList2 size` and the page size the initial library sync already
  /// uses. The listing is alphabetical, so a library past the cap silently
  /// loses gained-song detection for its late-alphabet tail — live QA proved
  /// this with an 8-page cap against a 7,746-album library. 24 pages covers
  /// 12,000 albums (three times the QA library, an order of magnitude past
  /// the ~1k-album production library) in at most 24 light metadata requests;
  /// the loop stops at the first short page, so normal libraries never pay
  /// the worst case.
  public static let albumTrackCountPageSize = 500
  public static let maxAlbumTrackCountPages = 24

  private let storage: CoreDataCompanion
  private let librarySyncer: LibrarySyncer
  private let account: Account
  private let store: SmartPlaylistStore
  private let playlistItemsSyncTracker: PlaylistItemsSyncTracker
  private let eventLogger: EventLogger?

  private let log = OSLog(subsystem: "Amperfy", category: "SmartPlaylistRefresher")

  public init(
    storage: CoreDataCompanion,
    librarySyncer: LibrarySyncer,
    account: Account,
    store: SmartPlaylistStore = .shared,
    playlistItemsSyncTracker: PlaylistItemsSyncTracker = .shared,
    eventLogger: EventLogger? = nil
  ) {
    self.storage = storage
    self.librarySyncer = librarySyncer
    self.account = account
    self.store = store
    self.playlistItemsSyncTracker = playlistItemsSyncTracker
    self.eventLogger = eventLogger
  }

  // MARK: - Entry point

  /// Refreshes the smart playlist for `query` and persists the frozen result.
  ///
  /// - Parameters:
  ///   - query: the rules to evaluate.
  ///   - isOnline: whether server round-trips are allowed. Callers source this
  ///     from the existing offline-mode setting, i.e.
  ///     `settings.user.isOnlineMode && networkMonitor.isConnectedToNetwork`
  ///     (same guard `PlaylistSyncWorker` uses).
  ///   - now: injectable clock for deterministic tests.
  ///   - progress: called on the main actor at each phase boundary.
  ///
  /// Never throws: sync failures are reported through `eventLogger` (without a
  /// popup) and downgrade the refresh to whatever data is already local, which
  /// is strictly better than failing the user's explicit tap.
  @discardableResult
  public func refresh(
    query: SmartPlaylistQuery,
    isOnline: Bool,
    now: Date = Date(),
    progress: ((SmartPlaylistRefreshPhase) -> ())? = nil
  ) async
    -> SmartPlaylistRefreshOutcome {
    var albumsBackfilled = 0

    if isOnline, let addedWithinDays = query.addedWithinDays {
      await refreshAlbumTrackCounts(progress: progress)
      albumsBackfilled = await backfillRecentSongs(
        addedWithinDays: addedWithinDays,
        now: now,
        progress: progress
      )
    }

    if isOnline, query.requiresPlaylistItems {
      await syncUnsyncedPlaylists(progress: progress)
    }

    progress?(.evaluating)
    let evaluation = SmartPlaylistQueryEngine.evaluate(
      query: query,
      context: storage.context,
      account: account,
      now: now
    )

    let hasIncompletePlaylistData = query.requiresPlaylistItems && !unsyncedPlaylistIds().isEmpty

    let state = SmartPlaylistState(
      query: query,
      frozenSongIds: evaluation.songs.map { $0.id },
      refreshedAt: now,
      wasOfflineRefresh: !isOnline,
      songsMissingAddedDate: evaluation.songsMissingAddedDate
    )
    store.save(state)
    progress?(.finished)

    os_log(
      "SmartPlaylistRefresher: %d songs, %d albums backfilled, offline=%d",
      log: log,
      type: .info,
      evaluation.songs.count,
      albumsBackfilled,
      isOnline ? 0 : 1
    )

    return SmartPlaylistRefreshOutcome(
      state: state,
      songs: evaluation.songs,
      wasOfflineRefresh: !isOnline,
      hasIncompletePlaylistData: hasIncompletePlaylistData,
      droppedPlaylistRules: evaluation.droppedPlaylistRules,
      albumsBackfilled: albumsBackfilled
    )
  }

  // MARK: - Step 1: album track-count refresh

  /// Relearns every album's server-reported track count before anything reads
  /// one.
  ///
  /// # Why this pass has to exist
  ///
  /// The gained-songs scan (backfill pass 2) finds its candidates by comparing
  /// `Album.remoteSongCount` with the songs we hold. That comparison is only as
  /// good as the count, and the count is written **only** when an album listing
  /// containing that album is parsed. The newest-albums walk stops at the
  /// query window, so an OLD album that gains a song server-side (its
  /// `created_at` never moves, so it never re-enters the `newest` pages) keeps
  /// its stale count forever. Live QA proved it: local count 3, server count 4,
  /// the new song added today — pass 2's candidate set was empty and "Added in
  /// the last 7 days" returned nothing, through refreshes and relaunches alike.
  ///
  /// # The primitive
  ///
  /// `syncAlbumListPage` — one page of the FULL album listing
  /// (`getAlbumList2 type=alphabeticalByName` on Subsonic, `albums` on Ampache),
  /// which is exactly what the initial library sync pages through. It is the
  /// cheapest correct option available in the client's API surface: light
  /// album-level metadata only (no song XML), a stable ordering that covers
  /// every album rather than a recency slice, an existing parser that already
  /// writes `remoteSongCount` (and clears `isSongsMetaDataSynced` when the
  /// count moved), and no newest/recent section bookkeeping to pollute.
  ///
  /// Cost for the workshop's ~1,000-album production library: **3 requests**
  /// (500 + 500 + a short page), only on a refresh whose query actually has an
  /// `addedWithinDays` rule, at most once per refresh. Refresh is an explicit,
  /// spinner-blocking user action, so paying it there is the right trade.
  private func refreshAlbumTrackCounts(progress: ((SmartPlaylistRefreshPhase) -> ())?) async {
    var albumsScanned = 0

    for pageIndex in 0 ..< Self.maxAlbumTrackCountPages {
      progress?(.refreshingAlbumTrackCounts(albumsScanned: albumsScanned))

      let albumsOnPage: Int
      do {
        albumsOnPage = try await librarySyncer.syncAlbumListPage(
          offset: pageIndex * Self.albumTrackCountPageSize,
          count: Self.albumTrackCountPageSize
        )
      } catch {
        report(error: error, topic: "Smart Playlist Album Track Count Refresh")
        break
      }

      albumsScanned += albumsOnPage
      progress?(.refreshingAlbumTrackCounts(albumsScanned: albumsScanned))
      // A short page is the end of the listing.
      guard albumsOnPage == Self.albumTrackCountPageSize else { break }
    }

    storage.saveContext()
    os_log(
      "SmartPlaylistRefresher: refreshed track counts for %d albums",
      log: log,
      type: .info,
      albumsScanned
    )
  }

  // MARK: - Step 2: recent-songs backfill

  /// Makes song-level `addedDate` exist for everything the window could match,
  /// then lets song dates — never album dates — decide when to stop.
  ///
  /// # Why two passes
  ///
  /// The V1 backfill walked `getAlbumList2 type=newest` and stopped at the first
  /// page with nothing inside the window. That ordering is keyed on the ALBUM's
  /// created date, so an OLD album that gained NEW songs is invisible to it —
  /// the real "Joshua" case (album created 2026-03-22, songs added 2026-07-10)
  /// sat hundreds of albums past the stop point and was never fetched. Worse,
  /// `needsSongSync` skipped it anyway because its existing songs all had dates.
  ///
  /// Our Navidrome fork's Subsonic surface has no song-level recency primitive
  /// to replace the walk with (investigated 2026-08-17, see the module README):
  /// `search3` takes no sort parameter and orders an empty query by
  /// `media_file.rowid ASC`, and `getAlbumList2` has no song-level twin. So the
  /// addendum's sanctioned fallback applies — sync candidate albums' songs, then
  /// decide from song dates — with a second pass that finds the candidates the
  /// newest-albums ordering structurally cannot:
  ///
  ///  1. **Newest-albums walk** — genuinely new albums. Unchanged except that
  ///     the stop condition is now stated as song-level.
  ///  2. **Gained-songs scan** — albums the local library knows are short:
  ///     `remoteSongCount` exceeds the number of songs we hold. That is exactly
  ///     the "old album, new songs" shape. It reads counts that
  ///     `refreshAlbumTrackCounts` has just made current — without that step it
  ///     compares against whatever a past listing happened to leave behind, and
  ///     for an album no recency listing ever returns that is stale forever.
  ///     Albums holding `nil`-added-date songs (synced before the
  ///     fractional-seconds parsing fix) follow, lowest priority.
  ///
  /// Both passes share one `maxBackfillAlbums` budget so a refresh stays bounded.
  ///
  /// Returns the number of albums processed.
  private func backfillRecentSongs(
    addedWithinDays: Int,
    now: Date,
    progress: ((SmartPlaylistRefreshPhase) -> ())?
  ) async
    -> Int {
    var albumsProcessed = await backfillNewestAlbums(
      addedWithinDays: addedWithinDays,
      now: now,
      progress: progress
    )
    albumsProcessed += await backfillAlbumsWithUnfetchedSongs(
      albumsAlreadyProcessed: albumsProcessed,
      progress: progress
    )
    return albumsProcessed
  }

  /// Pass 1 — pages `getAlbumList2 type=newest` and syncs each page's album
  /// songs until an entire page has no SONG inside the query window, or a cap is
  /// hit. The newest-first ordering guarantees that once a full page is outside
  /// the window, no later page holds a newer *album* — the songs that ordering
  /// misses are pass 2's job.
  private func backfillNewestAlbums(
    addedWithinDays: Int,
    now: Date,
    progress: ((SmartPlaylistRefreshPhase) -> ())?
  ) async
    -> Int {
    let cutoff = SmartPlaylistQueryEngine.cutoffDate(daysAgo: addedWithinDays, from: now)
    var albumsProcessed = 0

    pageLoop: for pageIndex in 0 ..< Self.maxBackfillPages {
      let offset = pageIndex * Self.backfillPageSize
      reportProgress(albumsProcessed: albumsProcessed, progress: progress)

      do {
        try await librarySyncer.syncNewestAlbums(
          offset: offset,
          count: Self.backfillPageSize
        )
      } catch {
        report(error: error, topic: "Smart Playlist Newest Albums Sync")
        break pageLoop
      }

      let pageAlbums = storage.library.getNewestAlbums(
        for: account,
        offset: offset,
        count: Self.backfillPageSize
      )
      guard !pageAlbums.isEmpty else { break pageLoop }

      var pageContainsSongInsideWindow = false
      for album in pageAlbums {
        guard albumsProcessed < Self.maxBackfillAlbums else { break pageLoop }

        if needsSongSync(album: album) {
          await syncSongs(of: album)
        }
        albumsProcessed += 1
        if let newestSongAddedDate = newestSongAddedDate(of: album),
           newestSongAddedDate >= cutoff {
          pageContainsSongInsideWindow = true
        }
        reportProgress(albumsProcessed: albumsProcessed, progress: progress)
      }
      storage.saveContext()

      // Song-level stop: a page whose albums hold no song inside the window,
      // in a newest-first listing, means no later page holds one either.
      guard pageContainsSongInsideWindow else { break pageLoop }
      // A short page is the end of the list.
      guard pageAlbums.count == Self.backfillPageSize else { break pageLoop }
    }

    return albumsProcessed
  }

  /// Pass 2 — the "Joshua" pass. Syncs songs for albums the local library shows
  /// as incomplete, highest-signal first, until the shared album budget runs
  /// out. Finding the candidates costs no further network calls, because
  /// `refreshAlbumTrackCounts` has already brought the counts it reads up to
  /// date.
  ///
  /// Known limit: on a fresh install nothing has been song-synced yet, so no
  /// album can look "short" and this pass finds nothing — first-refresh
  /// coverage is whatever pass 1's caps allow. Closing that gap needs a
  /// song-level recency endpoint on the server (module README, "Backfill").
  private func backfillAlbumsWithUnfetchedSongs(
    albumsAlreadyProcessed: Int,
    progress: ((SmartPlaylistRefreshPhase) -> ())?
  ) async
    -> Int {
    let remainingBudget = Self.maxBackfillAlbums - albumsAlreadyProcessed
    guard remainingBudget > 0 else { return 0 }

    let candidateAlbums = Array(albumsWithUnfetchedSongs().prefix(remainingBudget))
    guard !candidateAlbums.isEmpty else { return 0 }

    var albumsProcessed = 0
    for album in candidateAlbums {
      await syncSongs(of: album)
      albumsProcessed += 1
      reportProgress(
        albumsProcessed: albumsAlreadyProcessed + albumsProcessed,
        progress: progress
      )
    }
    storage.saveContext()
    return albumsProcessed
  }

  /// Albums that certainly hold songs we have not fetched, most-likely-relevant
  /// first:
  ///
  ///  1. albums whose server-reported `remoteSongCount` exceeds the songs we
  ///     hold, and which we have fetched before — they GAINED tracks;
  ///  2. albums we hold songs for whose `addedDate` never parsed (pre-fix
  ///     sync), which are indistinguishable from "no date" at query time.
  ///
  /// Albums with no local songs at all are deliberately excluded: on a fresh
  /// install that is the entire library, and pass 1 already walks it
  /// newest-first.
  private func albumsWithUnfetchedSongs() -> [Album] {
    var albumsThatGainedSongs = [Album]()
    var albumsWithUndatedSongs = [Album]()

    for album in storage.library.getAlbums(for: account) {
      let localSongs = album.songs.compactMap { $0.asSong }
      guard !localSongs.isEmpty else { continue }
      if album.remoteSongCount > localSongs.count {
        albumsThatGainedSongs.append(album)
      } else if localSongs.contains(where: { $0.addedDate == nil }) {
        albumsWithUndatedSongs.append(album)
      }
    }
    return albumsThatGainedSongs + albumsWithUndatedSongs
  }

  /// An album needs its songs (re-)fetched when its song metadata was never
  /// synced, when the server says it holds more songs than we do, or when it
  /// holds songs with no `addedDate` — the last covers albums synced before the
  /// fractional-seconds parsing fix, whose songs carry a permanently `nil`
  /// added-date until refetched.
  private func needsSongSync(album: Album) -> Bool {
    guard album.isSongsMetaDataSynced else { return true }
    let songs = album.songs.compactMap { $0.asSong }
    guard !songs.isEmpty else { return true }
    guard album.remoteSongCount <= songs.count else { return true }
    return songs.contains { $0.addedDate == nil }
  }

  private func newestSongAddedDate(of album: Album) -> Date? {
    album.songs.compactMap { $0.asSong?.addedDate }.max()
  }

  private func syncSongs(of album: Album) async {
    do {
      try await librarySyncer.sync(album: album)
    } catch {
      report(error: error, topic: "Smart Playlist Album Song Sync")
    }
  }

  private func reportProgress(
    albumsProcessed: Int,
    progress: ((SmartPlaylistRefreshPhase) -> ())?
  ) {
    progress?(.backfillingRecentSongs(
      albumsProcessed: albumsProcessed,
      albumsCap: Self.maxBackfillAlbums
    ))
  }

  // MARK: - Step 3: playlist item drain

  /// Fetches items for every non-smart playlist the tracker reports as
  /// unsynced. Same filter idiom as `PlaylistSyncWorker.fetchUnsyncedPlaylistInfo`
  /// including the remote-edit reconcile, so a playlist edited server-side
  /// since our last item sync is refetched too.
  private func syncUnsyncedPlaylists(progress: ((SmartPlaylistRefreshPhase) -> ())?) async {
    let unsyncedPlaylists = unsyncedPlaylists()
    guard !unsyncedPlaylists.isEmpty else { return }

    let totalPlaylists = unsyncedPlaylists.count
    progress?(.syncingPlaylists(done: 0, total: totalPlaylists))
    for (index, playlist) in unsyncedPlaylists.enumerated() {
      do {
        try await librarySyncer.syncDown(playlist: playlist)
        playlistItemsSyncTracker.markSynced(
          playlist.id,
          remoteSongCount: playlist.remoteSongCount
        )
      } catch {
        report(error: error, topic: "Smart Playlist Playlist Items Sync")
      }
      progress?(.syncingPlaylists(done: index + 1, total: totalPlaylists))
    }
  }

  private func unsyncedPlaylists() -> [Playlist] {
    let allPlaylists = storage.library.getPlaylists(
      for: account,
      areSystemPlaylistsIncluded: false
    )
    for playlist in allPlaylists where !playlist.isSmartPlaylist {
      playlistItemsSyncTracker.reconcile(
        playlistId: playlist.id,
        remoteSongCount: playlist.remoteSongCount
      )
    }
    return allPlaylists.filter {
      !$0.isSmartPlaylist && !playlistItemsSyncTracker.isSynced($0.id)
    }
  }

  private func unsyncedPlaylistIds() -> [String] {
    unsyncedPlaylists().map { $0.id }
  }

  // MARK: - Errors

  private func report(error: Error, topic: String) {
    os_log(
      "SmartPlaylistRefresher: %{public}@ failed: %{public}@",
      log: log,
      type: .error,
      topic,
      error.localizedDescription
    )
    eventLogger?.report(topic: topic, error: error, displayPopup: false)
  }
}
