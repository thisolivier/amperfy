//
//  BackgroundRunnerFeatureFlags.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 19a — Background task runner).
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

// MARK: - BackgroundRunnerFeatureFlags

/// UserDefaults-backed feature flags for the background task runner.
/// Supports DI of a test `UserDefaults` instance for unit testing.
public final class BackgroundRunnerFeatureFlags: @unchecked Sendable {
  public static let shared = BackgroundRunnerFeatureFlags()

  private let defaults: UserDefaults

  private enum Key {
    static let phase2Enabled = "amperfy.fork.runner.phase2Enabled"
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Phase 2 (playlist item sync). Default OFF.
  /// When false, `.playlistItemSync` tasks are rejected with `.disabled` status.
  /// Stays off until Olivier validates memory profile on a large device library.
  public var phase2Enabled: Bool {
    get { defaults.bool(forKey: Key.phase2Enabled) }
    set { defaults.set(newValue, forKey: Key.phase2Enabled) }
  }
}
