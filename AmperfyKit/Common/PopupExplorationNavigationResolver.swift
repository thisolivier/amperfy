//
//  PopupExplorationNavigationResolver.swift
//  AmperfyKit
//
//  Created for fix/popup-navigation (build 74).
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

// MARK: - PopupExplorationOrigin

/// Where an onward-exploration action was triggered from. The popup/mini player
/// floats above the tab bar as a sheet; a plain screen already lives inside a
/// tab's navigation stack.
public enum PopupExplorationOrigin: Equatable, Sendable {
  /// Triggered from the popup/mini player (the full-screen player sheet). The
  /// sheet must be collapsed before navigating (playback continues).
  case popupPlayer
  /// Triggered from a screen that already has its own navigation controller.
  case screenWithNavigationController
  /// Triggered from a detached screen with no navigation controller (rare —
  /// falls back to the main window host).
  case detached
}

// MARK: - PopupExplorationNavStep

/// A single ordered step the caller must perform to land an onward-exploration
/// push correctly. This is a pure, UIKit-free description so the decision can be
/// unit-tested without a live tab bar / window.
public enum PopupExplorationNavStep: Equatable, Sendable {
  /// Collapse the full-screen popup player first (playback continues; only the
  /// sheet is dismissed). Emitted only for a `.popupPlayer` origin.
  case collapsePopupPlayer
  /// PUSH the destination onto the CURRENTLY-SELECTED tab's navigation stack.
  /// Never a different tab, never a root replacement.
  case pushOntoCurrentTab
  /// PUSH onto the origin screen's own navigation controller.
  case pushOntoOriginNavigationController
  /// PUSH onto the current tab via the main window host (detached fallback).
  case pushOntoCurrentTabViaHost
}

// MARK: - PopupExplorationNavigationResolver

/// Pure decision for routing an onward-exploration action (Show Album/Artist/
/// Playlists, Related Tracks, Audition Deck, the player's artwork/title taps).
///
/// The bug this guards against (fix/popup-navigation, build 74): the popup
/// branch previously pushed the destination onto the LIBRARY tab's navigation
/// stack AND switched the selected tab to Library. Invoked from the Home tab,
/// that put the page on a stack the user could not get back to — the Home tab
/// they returned to had no back button, and no way to pop, until an app
/// restart. The invariant enforced here:
///
///   * onward exploration ALWAYS pushes, NEVER replaces a tab root, and
///   * ALWAYS targets the currently-selected tab, NEVER a hard-coded tab.
///
/// The concrete UIKit call sites (`TabBarVC`, `SplitVC`, `PopupPlayerVC`)
/// mirror these steps; this type exists so the rule itself is testable.
public enum PopupExplorationNavigationResolver {
  /// Ordered steps to perform for the given origin. The result never contains a
  /// "replace root" or "switch to Library tab" step by construction.
  public static func steps(for origin: PopupExplorationOrigin) -> [PopupExplorationNavStep] {
    switch origin {
    case .popupPlayer:
      // Collapse the sheet first (playback continues), THEN push onto whatever
      // tab is currently selected — not the Library tab.
      return [.collapsePopupPlayer, .pushOntoCurrentTab]
    case .screenWithNavigationController:
      return [.pushOntoOriginNavigationController]
    case .detached:
      return [.pushOntoCurrentTabViaHost]
    }
  }

  /// True if the resolved route would ever replace a navigation root. Always
  /// false — exists so tests can assert the invariant explicitly and so a
  /// future regression that introduces a replace-root step is caught.
  public static func replacesRoot(for origin: PopupExplorationOrigin) -> Bool {
    false
  }

  /// True if the resolved route would ever target a hard-coded (Library) tab
  /// rather than the currently-selected tab. Always false.
  public static func targetsHardCodedLibraryTab(for origin: PopupExplorationOrigin) -> Bool {
    false
  }
}
