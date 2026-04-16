//
//  GradientTest.swift
//  AmperfyKitTests
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

@testable import AmperfyKit
import XCTest

/// Unit tests for the PR 17.2 `ThemeGradient` model and its history helper.
/// Kept in AmperfyKitTests (not AmperfyTests) because `ThemeGradient` lives
/// in AmperfyKit specifically to dodge the Amperfy-app-target `@testable`
/// import blocker (VYPlayIndicator) observed in Release 1 QA.
final class GradientTest: XCTestCase {
  // MARK: - Codable round-trip

  /// Round-trip a gradient through JSON and verify every field survives.
  /// This is the exact path used by ThemeStore when persisting to
  /// UserDefaults, so a regression here would silently drop user data.
  func testCodableRoundTrip() throws {
    let gradient = ThemeGradient(
      colors: ["#FF0000", "#00FF00", "#0000FF"],
      direction: .topLeftToBottomRight
    )

    let data = try JSONEncoder().encode(gradient)
    let decoded = try JSONDecoder().decode(ThemeGradient.self, from: data)

    XCTAssertEqual(decoded.colors, gradient.colors)
    XCTAssertEqual(decoded.direction, gradient.direction)
    XCTAssertEqual(decoded.id, gradient.id)
    XCTAssertEqual(decoded, gradient)
  }

  /// Round-trip an array (matches the `gradientHistory` persistence path).
  func testCodableArrayRoundTrip() throws {
    let gradients = ThemeGradient.builtInPresets
    let data = try JSONEncoder().encode(gradients)
    let decoded = try JSONDecoder().decode([ThemeGradient].self, from: data)

    XCTAssertEqual(decoded.count, gradients.count)
    XCTAssertEqual(decoded, gradients)
  }

  // MARK: - Direction raw-value stability

  /// The `Direction` raw values are persisted to UserDefaults — renaming
  /// a case's raw value would invalidate everyone's saved gradients.
  /// This test locks the exact string values.
  func testDirectionRawValuesAreStable() {
    XCTAssertEqual(ThemeGradient.Direction.topToBottom.rawValue, "topToBottom")
    XCTAssertEqual(ThemeGradient.Direction.bottomToTop.rawValue, "bottomToTop")
    XCTAssertEqual(ThemeGradient.Direction.leftToRight.rawValue, "leftToRight")
    XCTAssertEqual(ThemeGradient.Direction.rightToLeft.rawValue, "rightToLeft")
    XCTAssertEqual(
      ThemeGradient.Direction.topLeftToBottomRight.rawValue,
      "topLeftToBottomRight"
    )
    XCTAssertEqual(
      ThemeGradient.Direction.topRightToBottomLeft.rawValue,
      "topRightToBottomLeft"
    )
    XCTAssertEqual(ThemeGradient.Direction.allCases.count, 6)
  }

  // MARK: - Content equality

  /// `matchesContent(of:)` ignores UUID — used by history dedup so the
  /// same color list + direction doesn't appear twice even if the caller
  /// constructs a fresh ThemeGradient (new UUID) each time.
  func testMatchesContentIgnoresID() {
    let first = ThemeGradient(
      colors: ["#AAAAAA", "#BBBBBB"],
      direction: .topToBottom
    )
    let second = ThemeGradient(
      colors: ["#AAAAAA", "#BBBBBB"],
      direction: .topToBottom
    )

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertTrue(first.matchesContent(of: second))
  }

  func testMatchesContentDetectsDifferentColors() {
    let first = ThemeGradient(
      colors: ["#AAAAAA", "#BBBBBB"],
      direction: .topToBottom
    )
    let second = ThemeGradient(
      colors: ["#CCCCCC", "#BBBBBB"],
      direction: .topToBottom
    )
    XCTAssertFalse(first.matchesContent(of: second))
  }

  func testMatchesContentDetectsDifferentDirection() {
    let first = ThemeGradient(
      colors: ["#AAAAAA", "#BBBBBB"],
      direction: .topToBottom
    )
    let second = ThemeGradient(
      colors: ["#AAAAAA", "#BBBBBB"],
      direction: .leftToRight
    )
    XCTAssertFalse(first.matchesContent(of: second))
  }

  // MARK: - History dedup & cap

  /// Remembering a gradient twice must keep it in the list only once,
  /// promoted to the head. Prevents the Previously-Used carousel from
  /// showing endless duplicates of the currently-selected gradient.
  func testRememberingGradientDedupsByContent() {
    var history: [ThemeGradient] = []
    let gradient = ThemeGradient(
      colors: ["#FF0000", "#00FF00"],
      direction: .topToBottom
    )
    let duplicate = ThemeGradient(
      colors: ["#FF0000", "#00FF00"],
      direction: .topToBottom
    )

    history.rememberingGradient(gradient)
    history.rememberingGradient(duplicate)

    XCTAssertEqual(history.count, 1)
    // Duplicate insertion should promote and replace, so the surviving
    // entry carries the most recently-inserted UUID.
    XCTAssertEqual(history.first?.id, duplicate.id)
  }

  /// Remembering a new gradient inserts at position 0 (most-recent-first).
  func testRememberingGradientPrepends() {
    var history: [ThemeGradient] = []
    let oldest = ThemeGradient(colors: ["#111111", "#222222"], direction: .topToBottom)
    let newest = ThemeGradient(colors: ["#333333", "#444444"], direction: .topToBottom)

    history.rememberingGradient(oldest)
    history.rememberingGradient(newest)

    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.first, newest)
    XCTAssertEqual(history.last, oldest)
  }

  /// Soft-cap enforcement: when the history exceeds `historySoftCap`,
  /// the oldest entries fall off the tail.
  func testRememberingGradientEnforcesSoftCap() {
    var history: [ThemeGradient] = []
    let cap = ThemeGradient.historySoftCap
    // Insert cap + 5 unique gradients.
    for index in 0 ..< (cap + 5) {
      let hex = String(format: "#%06X", index * 1_000)
      let gradient = ThemeGradient(
        colors: [hex, "#000000"],
        direction: .topToBottom
      )
      history.rememberingGradient(gradient)
    }

    XCTAssertEqual(history.count, cap)
    // First five inserted entries should have been trimmed from the tail.
    XCTAssertEqual(
      history.first?.colors.first,
      String(format: "#%06X", (cap + 4) * 1_000)
    )
  }

  // MARK: - Built-in presets

  /// Sanity check on the five curated starter gradients seeded on first
  /// launch. Any change here is a user-facing visual change and should
  /// be intentional.
  func testBuiltInPresetsShape() {
    let presets = ThemeGradient.builtInPresets
    XCTAssertEqual(presets.count, 5)
    for preset in presets {
      XCTAssertGreaterThanOrEqual(preset.colors.count, ThemeGradient.minColorCount)
      XCTAssertLessThanOrEqual(preset.colors.count, ThemeGradient.maxColorCount)
    }
  }

  /// Each built-in preset has a fixed UUID so the history-dedup logic can
  /// recognise them across re-seeds. Regressing to `UUID()` would cause
  /// duplicate presets to accumulate in the carousel on reinstall.
  func testBuiltInPresetsHaveFixedIDs() {
    let first = ThemeGradient.builtInPresets
    let second = ThemeGradient.builtInPresets
    XCTAssertEqual(first.map(\.id), second.map(\.id))
  }
}
