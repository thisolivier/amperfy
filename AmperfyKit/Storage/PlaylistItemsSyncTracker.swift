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
/// across sessions but are auto-invalidated when a playlist's server-reported
/// song count (`remoteSongCount`, captured cheaply during the bulk list sync)
/// no longer matches the number of items stored locally. That mismatch means
/// the playlist was edited on the server after we last synced its items, so
/// the stale local items must be re-fetched. Without this, features that read
/// the local `items` relationship (e.g. "Show in Playlists" reverse membership)
/// silently return incomplete results.
public final class PlaylistItemsSyncTracker: @unchecked Sendable {
  public static let shared = PlaylistItemsSyncTracker()

  private let defaultsKey = "amperfy.fork.syncedPlaylistItems"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var syncedIds: Set<String> {
    get { Set(defaults.stringArray(forKey: defaultsKey) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: defaultsKey) }
  }

  public func isSynced(_ playlistId: String) -> Bool {
    syncedIds.contains(playlistId)
  }

  public func markSynced(_ playlistId: String) {
    var current = syncedIds
    current.insert(playlistId)
    syncedIds = current
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

  /// Returns `true` when the server-reported song count differs from the number
  /// of items stored locally — i.e. the playlist was edited on the server after
  /// we last synced it, so the local items are stale.
  ///
  /// A remote count of `0` is treated as unknown/unavailable (the bulk list sync
  /// may not have populated it yet) and never triggers invalidation, so we don't
  /// churn playlists we have no authoritative count for.
  public func hasCountMismatch(localItemCount: Int, remoteSongCount: Int) -> Bool {
    guard remoteSongCount > 0 else { return false }
    return localItemCount != remoteSongCount
  }

  /// Reconciles a synced playlist against its server-reported count and clears
  /// the synced flag when they diverge. No-op for playlists that are already
  /// unsynced or whose counts agree. Returns `true` if the playlist was
  /// invalidated (i.e. it now needs a re-sync).
  @discardableResult
  public func reconcile(
    playlistId: String,
    localItemCount: Int,
    remoteSongCount: Int
  )
    -> Bool {
    guard syncedIds.contains(playlistId) else { return false }
    guard hasCountMismatch(localItemCount: localItemCount, remoteSongCount: remoteSongCount)
    else { return false }
    invalidate(playlistId)
    return true
  }
}
