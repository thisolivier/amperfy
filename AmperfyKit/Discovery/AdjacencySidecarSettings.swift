//
//  AdjacencySidecarSettings.swift
//  AmperfyKit
//
//  UserDefaults-backed settings for the adjacency-sidecar's port. Same host as
//  the active account's Navidrome server (see AdjacencySidecarClient), just a
//  different port — prod 8787 / QA 8788 per project CLAUDE.md. No settings UI
//  this sprint; this is storage only, for a future settings screen to bind to.
//
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

/// Local-only adjacency-sidecar port setting, backed by UserDefaults.
/// Follows the same pattern as `AmperfyKit/Favorites/PinnedPlaylistStore.swift`.
public final class AdjacencySidecarSettings: @unchecked Sendable {
  public static let shared = AdjacencySidecarSettings()

  public static let defaultPort = 8787

  private let defaultsKey = "amperfy.fork.discovery.sidecarPort"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The adjacency-sidecar's port. Defaults to `8787` (prod) when unset.
  public var port: Int {
    get {
      let stored = defaults.integer(forKey: defaultsKey)
      return stored == 0 ? Self.defaultPort : stored
    }
    set { defaults.set(newValue, forKey: defaultsKey) }
  }
}
