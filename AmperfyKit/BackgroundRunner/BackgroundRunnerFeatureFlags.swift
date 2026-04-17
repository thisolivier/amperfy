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
    static let runnerEnabled = "amperfy.fork.runner.enabled"
    static let phase2Enabled = "amperfy.fork.runner.phase2Enabled"
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Kill-switch for the entire runner. Default ON.
  /// If false, `runner.enqueue()` is a no-op and existing code paths run
  /// unmodified. The status panel shows "Disabled" for all task kinds.
  ///
  /// Uses `object(forKey:) == nil` check so a missing key defaults to true,
  /// since `bool(forKey:)` returns `false` for missing keys.
  public var runnerEnabled: Bool {
    get {
      defaults.object(forKey: Key.runnerEnabled) == nil
        ? true
        : defaults.bool(forKey: Key.runnerEnabled)
    }
    set {
      defaults.set(newValue, forKey: Key.runnerEnabled)
    }
  }

  /// Phase 2 (playlist item sync). Default OFF.
  /// When false, `.playlistItemSync` tasks are rejected with `.disabled` status.
  public var phase2Enabled: Bool {
    get { defaults.bool(forKey: Key.phase2Enabled) }
    set { defaults.set(newValue, forKey: Key.phase2Enabled) }
  }
}
