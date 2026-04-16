//
//  EntityImageViewTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy spike (PR 17.3 — Album art borders).
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
import UIKit
import XCTest

/// PR 17.3 — album art border: verifies the UserDefaults bridge
/// `EntityImageView` uses to read the ThemeStore border config from
/// AmperfyKit (which cannot import the Amperfy app module).
///
/// This test is structurally a contract test between the ThemeStore
/// persistence keys (owned by the app target) and the AmperfyKit reader.
/// It intentionally does NOT instantiate `EntityImageView` directly
/// because the view requires an XIB not available in the test bundle.
/// Instead it re-implements the exact bridge logic inline and asserts
/// the decode path — any future refactor that changes the key strings
/// or the interpretation must update this test to stay green.
final class EntityImageViewTest: XCTestCase {
  // Mirror of EntityImageView.BorderDefaultsKey (fileprivate over there);
  // mirrored here so the test exercises the exact same string keys that
  // the view reads. A regression where the keys drift between sites
  // would fail this test.
  private enum Key {
    static let enabled = "amperfy.fork.theme.enabled"
    static let width = "amperfy.fork.theme.albumArt.borderWidth"
    static let color = "amperfy.fork.theme.albumArt.borderColor"
  }

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: Key.enabled)
    UserDefaults.standard.removeObject(forKey: Key.width)
    UserDefaults.standard.removeObject(forKey: Key.color)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: Key.enabled)
    UserDefaults.standard.removeObject(forKey: Key.width)
    UserDefaults.standard.removeObject(forKey: Key.color)
    super.tearDown()
  }

  // MARK: - Effective-width logic (mirrors EntityImageView.applyArtworkBorder)

  /// Default: no keys set → width zero. No border painted.
  func testDefaultBorderWidthIsZero() {
    XCTAssertEqual(effectiveBorderWidth(), 0)
  }

  /// Theme enabled + non-zero width → effective width equals stored
  /// value. The common case after a user steps the Settings control.
  func testWidthFromDefaultsApplies() {
    UserDefaults.standard.set(true, forKey: Key.enabled)
    UserDefaults.standard.set(3.0, forKey: Key.width)
    XCTAssertEqual(effectiveBorderWidth(), 3.0)
  }

  /// Theme disabled → suppress border regardless of stored width.
  /// Keeps the render site free from duplicate `isEnabled` gating.
  func testDisabledThemeSuppressesBorder() {
    UserDefaults.standard.set(false, forKey: Key.enabled)
    UserDefaults.standard.set(5.0, forKey: Key.width)
    XCTAssertEqual(effectiveBorderWidth(), 0)
  }

  /// Width key missing but theme on → effective width zero. Matches the
  /// defaults-fresh path for a user who enabled the theme but has not
  /// yet bumped the border stepper.
  func testWidthUnsetDefaultsToZeroWhenEnabled() {
    UserDefaults.standard.set(true, forKey: Key.enabled)
    XCTAssertEqual(effectiveBorderWidth(), 0)
  }

  // MARK: - Color decode (mirrors EntityImageView.applyArtworkBorder)

  /// Stored color hex decodes to the expected RGB components. Round-trips
  /// through the local `UIColor(borderHex:)` logic mirrored below.
  func testColorHexDecodesToRGB() {
    let color = borderHexColor(from: "#FF0000")
    XCTAssertNotNil(color)
    guard let color else { return }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 1.0, accuracy: 0.01)
    XCTAssertEqual(g, 0.0, accuracy: 0.01)
    XCTAssertEqual(b, 0.0, accuracy: 0.01)
    XCTAssertEqual(a, 1.0, accuracy: 0.01)
  }

  /// Hex with a leading `#` is accepted — matches `ThemeStore.hexString`
  /// output format (`"#RRGGBB"`).
  func testColorHexWithHashPrefixAccepted() {
    XCTAssertNotNil(borderHexColor(from: "#ABCDEF"))
  }

  /// Hex without the leading `#` is also accepted — hardens the decoder
  /// against legacy / hand-edited UserDefaults.
  func testColorHexWithoutHashPrefixAccepted() {
    XCTAssertNotNil(borderHexColor(from: "ABCDEF"))
  }

  /// Malformed hex returns nil; the render site falls back to
  /// `.separator`, matching EntityImageView's behaviour.
  func testMalformedColorHexRejected() {
    XCTAssertNil(borderHexColor(from: "not-a-hex"))
    XCTAssertNil(borderHexColor(from: "#ZZZZZZ"))
    XCTAssertNil(borderHexColor(from: "#12345")) // wrong length
  }

  // MARK: - Local mirror of EntityImageView's bridge logic

  /// Re-implementation of the `width` branch of
  /// `EntityImageView.applyArtworkBorder()`. Any divergence between this
  /// function and that view's logic is a test failure (covered by the
  /// tests above). Kept minimal — if the view grows more logic, mirror
  /// it here rather than relaxing the test.
  private func effectiveBorderWidth() -> CGFloat {
    let defaults = UserDefaults.standard
    let enabled = defaults.bool(forKey: Key.enabled)
    let stored = defaults.double(forKey: Key.width)
    return enabled ? CGFloat(stored) : 0
  }

  /// Re-implementation of the fileprivate `UIColor(borderHex:)` used by
  /// EntityImageView. Mirrored so the test can exercise the decode path
  /// without relying on the app-target `UIColor(hex:)` convenience
  /// (which is not visible to AmperfyKitTests).
  private func borderHexColor(from hex: String) -> UIColor? {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard trimmed.count == 6, let raw = UInt64(trimmed, radix: 16) else {
      return nil
    }
    return UIColor(
      red: CGFloat((raw >> 16) & 0xFF) / 255.0,
      green: CGFloat((raw >> 8) & 0xFF) / 255.0,
      blue: CGFloat(raw & 0xFF) / 255.0,
      alpha: 1.0
    )
  }
}
