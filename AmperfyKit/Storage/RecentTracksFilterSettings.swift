//
//  RecentTracksFilterSettings.swift
//  AmperfyKit
//
//  Created for the Recently Added triage-filter feature.
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

// MARK: - RecentTracksFilterSettings

/// Persisted settings for the Recently Added detail screen's triage filter.
///
/// The user treats "Recently Added" as an inbox: new tracks arrive and get
/// filed into playlists. The `hideSongsInPlaylists` toggle removes tracks that
/// have already been filed into at least one real user playlist, so the list
/// shows only what still needs triaging.
///
/// Stored in the `amperfy.fork.*` namespace per fork settings convention.
/// `UserDefaults` is injectable so the store is unit-testable in isolation
/// (mirrors `AdjacencySidecarSettings` / `GigsSettings`).
public final class RecentTracksFilterSettings {
  private let hideSongsInPlaylistsKey = "amperfy.fork.recentTracks.hideSongsInPlaylists"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// When `true`, the Recently Added list hides tracks already filed into at
  /// least one real user playlist. Defaults to `false` (opt-in) so upgrading
  /// users see the unchanged, unfiltered list until they enable it.
  public var hideSongsInPlaylists: Bool {
    get { defaults.bool(forKey: hideSongsInPlaylistsKey) }
    set { defaults.set(newValue, forKey: hideSongsInPlaylistsKey) }
  }
}

// MARK: - RecentTracksFilterCaption

/// Pure formatter for the section-header filter caption (B2). Kept UIKit-free
/// and separate from the view controller so the presence/count logic is unit-
/// testable. Caption only — there is no toast anywhere in this feature.
public enum RecentTracksFilterCaption {
  /// The caption string for the section header, or `nil` when nothing should be
  /// shown.
  ///
  /// * Filter off ⇒ `nil` (header shows no caption).
  /// * Filter on  ⇒ `"Filtered · N unfiled"` where N is the current VISIBLE
  ///   (filtered) count, so it reads as the size of the remaining backlog.
  public static func text(hideSongsInPlaylists: Bool, visibleCount: Int) -> String? {
    guard hideSongsInPlaylists else { return nil }
    return "Filtered · \(visibleCount) unfiled"
  }
}
