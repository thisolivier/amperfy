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
  /// Paging `getAlbumList2 type=newest` and syncing each new album's songs so
  /// `addedDate` exists to filter on.
  case backfillingNewestAlbums(albumsProcessed: Int, albumsCap: Int)
  /// Fetching items for playlists that only have metadata locally.
  case syncingPlaylists(done: Int, total: Int)
  /// Running the Core Data fetch.
  case evaluating
  /// Result persisted; the outcome is being returned.
  case finished

  public var displayText: String {
    switch self {
    case let .backfillingNewestAlbums(albumsProcessed, _):
      return "Checking newest albums (\(albumsProcessed))…"
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
///  1. **Newest-albums backfill** (online, and only when the query has an
///     `addedWithinDays` rule). `addedDate` is populated exclusively by
///     song-level XML; the bulk album sync never sets it (see
///     `ADDED_DATE_INVESTIGATION.md`). So we page `getAlbumList2 type=newest`
///     and sync each fresh album's songs until a whole page is older than the
///     query window — bounded hard by `maxBackfillAlbums` / `maxBackfillPages`.
///  2. **Playlist item drain** (online, and only when the query has a playlist
///     rule). `PlaylistItemMO` rows exist only for individually fetched
///     playlists, so membership rules would otherwise answer from thin air.
///     Same unsynced-set idiom as `PlaylistSyncWorker`.
///  3. **Evaluate** — one compound fetch.
///  4. **Persist** the frozen result.
///
/// Offline, steps 1 and 2 are skipped and the result is flagged
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

    if isOnline, query.addedWithinDays != nil {
      albumsBackfilled = await backfillNewestAlbums(
        addedWithinDays: query.addedWithinDays!,
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

  // MARK: - Step 1: newest-albums backfill

  /// Pages `getAlbumList2 type=newest` and syncs each page's album songs until
  /// an entire page is older than the query window, or a cap is hit.
  ///
  /// The stop signal is derived from the albums' *songs* rather than an album
  /// `created` attribute because `AlbumMO` has no created/added column (no
  /// Core Data schema changes in V1) — but the newest-first ordering guarantees
  /// that once a full page has nothing inside the window, no later page will.
  ///
  /// Returns the number of albums processed.
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
      progress?(.backfillingNewestAlbums(
        albumsProcessed: albumsProcessed,
        albumsCap: Self.maxBackfillAlbums
      ))

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

      var pageContainsAlbumInsideWindow = false
      for album in pageAlbums {
        guard albumsProcessed < Self.maxBackfillAlbums else { break pageLoop }

        if needsSongSync(album: album) {
          do {
            try await librarySyncer.sync(album: album)
          } catch {
            report(error: error, topic: "Smart Playlist Album Song Sync")
          }
        }
        albumsProcessed += 1
        if let newestSongAddedDate = newestSongAddedDate(of: album),
           newestSongAddedDate >= cutoff {
          pageContainsAlbumInsideWindow = true
        }
        progress?(.backfillingNewestAlbums(
          albumsProcessed: albumsProcessed,
          albumsCap: Self.maxBackfillAlbums
        ))
      }
      storage.saveContext()

      // Newest-first ordering: a page with nothing inside the window means
      // every later page is older still.
      guard pageContainsAlbumInsideWindow else { break pageLoop }
      // A short page is the end of the list.
      guard pageAlbums.count == Self.backfillPageSize else { break pageLoop }
    }

    return albumsProcessed
  }

  /// An album needs its songs (re-)fetched when its song metadata was never
  /// synced, or when it holds songs with no `addedDate` — the latter covers
  /// albums synced before the fractional-seconds parsing fix, whose songs
  /// carry a permanently `nil` added-date until refetched.
  private func needsSongSync(album: Album) -> Bool {
    guard album.isSongsMetaDataSynced else { return true }
    let songs = album.songs.compactMap { $0.asSong }
    guard !songs.isEmpty else { return true }
    return songs.contains { $0.addedDate == nil }
  }

  private func newestSongAddedDate(of album: Album) -> Date? {
    album.songs.compactMap { $0.asSong?.addedDate }.max()
  }

  // MARK: - Step 2: playlist item drain

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
