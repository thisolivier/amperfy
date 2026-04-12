//
//  PinnedPlaylistStore.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (Feature D — Favourites).
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

/// Local-only "favourite playlist" store backed by UserDefaults.
///
/// Deliberately NOT Core Data — avoids schema changes that would conflict
/// with upstream Amperfy data model migrations. See BACKLOG.md §D.2.1.
public final class PinnedPlaylistStore: @unchecked Sendable {
  public static let shared = PinnedPlaylistStore()

  public static let didChangeNotification = Notification.Name(
    "amperfy.fork.pinnedPlaylists.didChange"
  )

  private let defaultsKey = "amperfy.fork.pinnedPlaylists"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The set of pinned (favourited) playlist IDs (Subsonic playlist id strings).
  public var pinnedIds: Set<String> {
    get { Set(defaults.stringArray(forKey: defaultsKey) ?? []) }
    set {
      defaults.set(Array(newValue).sorted(), forKey: defaultsKey)
      NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
  }

  public func isPinned(_ playlistId: String) -> Bool {
    pinnedIds.contains(playlistId)
  }

  public func pin(_ playlistId: String) {
    var current = pinnedIds
    current.insert(playlistId)
    pinnedIds = current
  }

  public func unpin(_ playlistId: String) {
    var current = pinnedIds
    current.remove(playlistId)
    pinnedIds = current
  }

  /// Toggles the pinned state and returns the new state (`true` = pinned).
  @discardableResult
  public func toggle(_ playlistId: String) -> Bool {
    if isPinned(playlistId) {
      unpin(playlistId)
      return false
    } else {
      pin(playlistId)
      return true
    }
  }
}
