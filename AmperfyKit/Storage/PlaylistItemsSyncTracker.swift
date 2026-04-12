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
/// UserDefaults-backed to avoid Core Data schema changes. No auto-invalidation
/// on this first pass — synced flags persist across sessions.
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
}
