//
//  PlaylistItemsSyncTracker.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (Hotfix 4 — In Playlists sync).
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

/// Tracks which playlists have had their items (PlaylistItemMO) synced via
/// the per-playlist `getPlaylist` API call. The bulk `getPlaylists` endpoint
/// only returns playlist metadata — items are only populated when each
/// playlist is individually fetched.
///
/// UserDefaults-backed to avoid Core Data schema changes. Synced flags persist
/// across sessions and are auto-invalidated when a playlist is edited on the
/// SERVER after we last synced its items, so the stale local items get
/// re-fetched. Without this, features that read the local `items` relationship
/// (e.g. "Show in Playlists" reverse membership) silently return incomplete
/// results.
///
/// The edit signal is a CHANGE in the server-advertised song count
/// (`remoteSongCount`, captured cheaply during the bulk list sync) versus the
/// count we recorded the last time we synced this playlist's items — NOT a
/// mismatch between `remoteSongCount` and the number of local items.
///
/// Why the change (2026-07): the old rule invalidated whenever
/// `localItemCount != remoteSongCount`. But the server's `songCount` counts
/// podcast / directory / unavailable entries that Amperfy skips when building
/// the local `items` relationship (see SsPlaylistSongsParserDelegate). For any
/// playlist holding such an entry that gap is PERMANENT, so the old rule marked
/// the playlist stale on every pass forever — re-invalidating and re-fetching
/// every open, which is exactly the "Show in Playlists" blocking-sync storm.
/// Comparing the current remote count to the remote count at last sync closes
/// that: a persistent local/remote gap never churns, while a genuine server
/// edit (which moves `songCount`) still triggers a single re-sync.
public final class PlaylistItemsSyncTracker: @unchecked Sendable {
  public static let shared = PlaylistItemsSyncTracker()

  private let defaultsKey = "amperfy.fork.syncedPlaylistItems"
  /// playlistId -> the `remoteSongCount` observed at the moment we last marked
  /// the playlist synced. Compared against the current remote count to detect a
  /// server-side edit.
  private let lastSyncedRemoteCountKey = "amperfy.fork.syncedPlaylistRemoteCounts"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var syncedIds: Set<String> {
    get { Set(defaults.stringArray(forKey: defaultsKey) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: defaultsKey) }
  }

  private var lastSyncedRemoteCounts: [String: Int] {
    get { (defaults.dictionary(forKey: lastSyncedRemoteCountKey) as? [String: Int]) ?? [:] }
    set { defaults.set(newValue, forKey: lastSyncedRemoteCountKey) }
  }

  public func isSynced(_ playlistId: String) -> Bool {
    syncedIds.contains(playlistId)
  }

  public func markSynced(_ playlistId: String) {
    var current = syncedIds
    current.insert(playlistId)
    syncedIds = current
  }

  /// Marks a playlist synced AND records the server-advertised remote count at
  /// this moment, so a later reconcile can tell whether the server edited it.
  /// Prefer this over `markSynced(_:)` at real sync sites; the plain overload
  /// remains for callers that don't have the remote count to hand.
  public func markSynced(_ playlistId: String, remoteSongCount: Int) {
    markSynced(playlistId)
    var counts = lastSyncedRemoteCounts
    counts[playlistId] = remoteSongCount
    lastSyncedRemoteCounts = counts
  }

  public func markSynced(_ playlistIds: [String]) {
    var current = syncedIds
    playlistIds.forEach { current.insert($0) }
    syncedIds = current
  }

  /// Clears the synced flag for a playlist so its items are re-fetched on next access.
  public func invalidate(_ playlistId: String) {
    guard syncedIds.contains(playlistId) else { return }
    var current = syncedIds
    current.remove(playlistId)
    syncedIds = current
  }

  /// Wipes ALL synced flags and recorded baselines.
  ///
  /// This MUST be called whenever the local library store is wiped and refilled
  /// — most importantly a forced resync (`SyncVC` deletes every `PlaylistItemMO`
  /// via `cleanStorageOfObsoleteAccountEntries`, and the initial sync then
  /// repopulates only playlist *metadata*, not items). The tracker is
  /// UserDefaults-backed, so without this it survives the Core Data wipe and
  /// keeps reporting every playlist as "items synced" while Core Data holds zero
  /// items. That stale confidence is what makes "Show in Playlists" answer a
  /// definitive (and wrong) "not in any playlists" after a resync — and it also
  /// starves `PlaylistSyncWorker`, whose unsynced-set is empty, so the items are
  /// never re-fetched. Clearing here keeps the tracker honest against the store.
  public func clear() {
    defaults.removeObject(forKey: defaultsKey)
    defaults.removeObject(forKey: lastSyncedRemoteCountKey)
  }

  /// Returns `true` when the server-advertised song count has CHANGED since we
  /// last synced this playlist's items — i.e. it was edited on the server, so
  /// the local items are stale and must be re-fetched.
  ///
  /// A remote count of `0` is treated as unknown/unavailable (the bulk list sync
  /// may not have populated it yet) and never triggers invalidation, so we don't
  /// churn playlists we have no authoritative count for.
  ///
  /// When we have no recorded last-synced remote count (e.g. the playlist was
  /// marked synced by a caller that didn't record one), we do NOT invalidate:
  /// absent a baseline there is no evidence of an edit, and inventing one from
  /// the local item count reintroduces the podcast/unavailable-gap churn.
  public func hasRemoteEdit(playlistId: String, remoteSongCount: Int) -> Bool {
    guard remoteSongCount > 0 else { return false }
    guard let lastSyncedRemoteCount = lastSyncedRemoteCounts[playlistId] else { return false }
    return remoteSongCount != lastSyncedRemoteCount
  }

  /// Reconciles a synced playlist against its server-advertised count and clears
  /// the synced flag when the server edited it since last sync. No-op for
  /// playlists that are already unsynced or show no edit. Returns `true` if the
  /// playlist was invalidated (i.e. it now needs a re-sync).
  ///
  /// `localItemCount` is accepted for source compatibility but intentionally
  /// unused — see the type doc for why a local/remote gap is not an edit signal.
  @discardableResult
  public func reconcile(
    playlistId: String,
    localItemCount: Int = 0,
    remoteSongCount: Int
  )
    -> Bool {
    guard syncedIds.contains(playlistId) else { return false }
    guard hasRemoteEdit(playlistId: playlistId, remoteSongCount: remoteSongCount)
    else { return false }
    invalidate(playlistId)
    return true
  }
}
