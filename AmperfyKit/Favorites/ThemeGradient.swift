//
//  ThemeGradient.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 17.2 — Gradient backgrounds).
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

// MARK: - ThemeGradient

/// Pure data model for a user-configurable background gradient.
///
/// Named `ThemeGradient` rather than the more natural `Gradient` to avoid
/// colliding with `SwiftUI.Gradient`, which `AmperfyKit` already imports
/// in its player-visualizer code. Stored in the app-layer `ThemeStore`
/// (UserDefaults, JSON-encoded) and rendered by `GradientBackgroundView`
/// in the Amperfy app target. Kept in `AmperfyKit` so it can be
/// unit-tested without depending on the Amperfy app target (which drags
/// in `VYPlayIndicator` and blocks `@testable` imports — see Release 1
/// QA notes).
public struct ThemeGradient: Codable, Equatable, Hashable, Sendable {
  /// Direction of the linear gradient. The six cases cover the common
  /// axis-aligned and diagonal gradients; higher fidelity (angle pickers,
  /// radial gradients) is out of scope for PR 17.2.
  public enum Direction: String, Codable, CaseIterable, Sendable {
    case topToBottom
    case bottomToTop
    case leftToRight
    case rightToLeft
    case topLeftToBottomRight
    case topRightToBottomLeft
  }

  /// Minimum number of color stops per gradient (designer spec).
  ///
  /// PR 20: gradients are now exactly 2-stop (start + end). Both the
  /// min and max collapse to 2. The struct still accepts any count at
  /// init time for decode robustness (a stored pre-PR-20 install might
  /// hold a 3- or 4-stop gradient); readers should call
  /// `reducedToTwoStops()` before rendering.
  public static let minColorCount = 2
  /// Maximum number of color stops per gradient (designer spec). See
  /// `minColorCount` — PR 20 collapsed both to the same value.
  public static let maxColorCount = 2
  /// Soft cap on the persisted history list. Prevents unbounded growth
  /// in UserDefaults when a user experiments heavily in the editor.
  public static let historySoftCap = 20

  /// Hex color strings (e.g. `"#FF6B6B"`). Format matches the existing
  /// ThemeStore color persistence. Caller is responsible for respecting
  /// `minColorCount` / `maxColorCount` at UI boundaries; the struct stays
  /// tolerant of any count so decode is robust.
  public let colors: [String]
  public let direction: Direction
  public let id: UUID

  public init(colors: [String], direction: Direction, id: UUID = UUID()) {
    self.colors = colors
    self.direction = direction
    self.id = id
  }

  /// Content equality: two gradients are "the same" when they share the
  /// same ordered color list and direction, regardless of UUID. Used to
  /// dedup the Previously-Used history on insertion.
  public func matchesContent(of other: ThemeGradient) -> Bool {
    colors == other.colors && direction == other.direction
  }

  /// PR 20: normalise a stored gradient to exactly two stops. A decode
  /// from a pre-PR-20 UserDefaults blob may deliver a 3- or 4-stop
  /// gradient; rendering code and the 2-stop picker UI both want
  /// exactly start+end. Keeps the first and last color, discards the
  /// middle. No-op when the gradient is already 2-stop (or shorter,
  /// which the decode tolerance allows but no UI path produces).
  public func reducedToTwoStops() -> ThemeGradient {
    guard colors.count > 2, let first = colors.first, let last = colors.last else {
      return self
    }
    return ThemeGradient(colors: [first, last], direction: direction, id: id)
  }
}

// MARK: - Built-in presets

extension ThemeGradient {
  /// Five curated starter gradients seeded into `gradientHistory` on first
  /// launch. Names exist for internal reference only — the UI shows them
  /// inline in the carousel alongside user-created gradients.
  public static let builtInPresets: [ThemeGradient] = [
    // Sunset — warm, vivid
    ThemeGradient(
      colors: ["#FF6B6B", "#FFD93D"],
      direction: .topToBottom,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ),
    // Ocean — cool, calming
    ThemeGradient(
      colors: ["#1A2980", "#26D0CE"],
      direction: .topToBottom,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    ),
    // Midnight — dark-mode friendly, subtle
    ThemeGradient(
      colors: ["#232526", "#414345"],
      direction: .topToBottom,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    ),
    // Meadow — fresh, diagonal
    ThemeGradient(
      colors: ["#56AB2F", "#A8E063"],
      direction: .topLeftToBottomRight,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    ),
    // Paper — light-mode friendly, subtle
    ThemeGradient(
      colors: ["#F5F7FA", "#C3CFE2"],
      direction: .topToBottom,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    ),
  ]
}

// MARK: - History management

extension Array where Element == ThemeGradient {
  /// Prepend `gradient` to the history, removing any prior entry with the
  /// same colors+direction (content equality) to keep the palette clean.
  /// Caps the final array at `ThemeGradient.historySoftCap` by trimming
  /// from the tail (oldest entries fall off).
  public mutating func rememberingGradient(_ gradient: ThemeGradient) {
    removeAll { $0.matchesContent(of: gradient) }
    insert(gradient, at: 0)
    if count > ThemeGradient.historySoftCap {
      self = Array(prefix(ThemeGradient.historySoftCap))
    }
  }
}
