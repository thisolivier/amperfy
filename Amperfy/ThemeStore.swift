//
//  ThemeStore.swift
//  Amperfy
//
//  Created by the Amperfy spike (Feature F — Custom Styling Phase 2).
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

import UIKit

/// App-layer custom theme store backed by UserDefaults.
/// Follows the same pattern as PinnedPlaylistStore — no Core Data, no AmperfyKit changes.
final class ThemeStore: @unchecked Sendable {
  static let shared = ThemeStore()

  static let didChangeNotification = Notification.Name("amperfy.fork.theme.didChange")

  private enum Key {
    static let enabled = "amperfy.fork.theme.enabled"
    static let lightBackground = "amperfy.fork.theme.light.bg"
    static let lightText = "amperfy.fork.theme.light.text"
    static let lightTint = "amperfy.fork.theme.light.tint"
    static let darkBackground = "amperfy.fork.theme.dark.bg"
    static let darkText = "amperfy.fork.theme.dark.text"
    static let darkTint = "amperfy.fork.theme.dark.tint"
    static let fontFamily = "amperfy.fork.theme.fontFamily"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Enabled toggle

  var isEnabled: Bool {
    get { defaults.bool(forKey: Key.enabled) }
    set { defaults.set(newValue, forKey: Key.enabled) }
  }

  // MARK: - Color accessors

  var lightBackground: UIColor? {
    get { color(forKey: Key.lightBackground) }
    set { setColor(newValue, forKey: Key.lightBackground) }
  }
  var lightText: UIColor? {
    get { color(forKey: Key.lightText) }
    set { setColor(newValue, forKey: Key.lightText) }
  }
  var lightTint: UIColor? {
    get { color(forKey: Key.lightTint) }
    set { setColor(newValue, forKey: Key.lightTint) }
  }
  var darkBackground: UIColor? {
    get { color(forKey: Key.darkBackground) }
    set { setColor(newValue, forKey: Key.darkBackground) }
  }
  var darkText: UIColor? {
    get { color(forKey: Key.darkText) }
    set { setColor(newValue, forKey: Key.darkText) }
  }
  var darkTint: UIColor? {
    get { color(forKey: Key.darkTint) }
    set { setColor(newValue, forKey: Key.darkTint) }
  }

  // MARK: - Font

  var fontFamily: String? {
    get { defaults.string(forKey: Key.fontFamily) }
    set { defaults.set(newValue, forKey: Key.fontFamily) }
  }

  // MARK: - Resolved colors for current interface style

  func backgroundColor(for style: UIUserInterfaceStyle) -> UIColor? {
    guard isEnabled else { return nil }
    return style == .dark ? darkBackground : lightBackground
  }

  func textColor(for style: UIUserInterfaceStyle) -> UIColor? {
    guard isEnabled else { return nil }
    return style == .dark ? darkText : lightText
  }

  func tintColor(for style: UIUserInterfaceStyle) -> UIColor? {
    guard isEnabled else { return nil }
    return style == .dark ? darkTint : lightTint
  }

  // MARK: - Dynamic colors (auto-resolve light/dark)

  var dynamicBackground: UIColor? {
    guard isEnabled else { return nil }
    return UIColor { [self] traits in
      (traits.userInterfaceStyle == .dark ? darkBackground : lightBackground) ?? .systemBackground
    }
  }

  var dynamicText: UIColor? {
    guard isEnabled else { return nil }
    return UIColor { [self] traits in
      (traits.userInterfaceStyle == .dark ? darkText : lightText) ?? .label
    }
  }

  var dynamicSecondaryText: UIColor? {
    guard isEnabled else { return nil }
    return UIColor { [self] traits in
      let base = (traits.userInterfaceStyle == .dark ? darkText : lightText) ?? .label
      return base.withAlphaComponent(0.6)
    }
  }

  var dynamicTint: UIColor? {
    guard isEnabled else { return nil }
    return UIColor { [self] traits in
      (traits.userInterfaceStyle == .dark ? darkTint : lightTint) ?? .systemBlue
    }
  }

  // MARK: - Populate defaults from stock colors

  func populateDefaultsIfNeeded() {
    if lightBackground == nil {
      lightBackground = UIColor.systemBackground.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light))
    }
    if lightText == nil {
      lightText = UIColor.label.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light))
    }
    if lightTint == nil {
      lightTint = UIColor.systemBlue.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light))
    }
    if darkBackground == nil {
      darkBackground = UIColor.systemBackground.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .dark))
    }
    if darkText == nil {
      darkText = UIColor.label.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .dark))
    }
    if darkTint == nil {
      darkTint = UIColor.systemBlue.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .dark))
    }
  }

  // MARK: - Reset

  func resetToDefaults() {
    let allKeys = [
      Key.enabled, Key.lightBackground, Key.lightText, Key.lightTint,
      Key.darkBackground, Key.darkText, Key.darkTint, Key.fontFamily,
    ]
    for key in allKeys {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - Notify

  func postChangeNotification() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  // MARK: - Hex persistence

  private func color(forKey key: String) -> UIColor? {
    guard let hex = defaults.string(forKey: key) else { return nil }
    return UIColor(hex: hex)
  }

  private func setColor(_ color: UIColor?, forKey key: String) {
    if let color {
      defaults.set(color.hexString, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - Contrast check

  /// Returns the WCAG contrast ratio between two colors (1.0–21.0).
  static func contrastRatio(between colorA: UIColor, and colorB: UIColor) -> CGFloat {
    let luminanceA = relativeLuminance(of: colorA)
    let luminanceB = relativeLuminance(of: colorB)
    let lighter = max(luminanceA, luminanceB)
    let darker = min(luminanceA, luminanceB)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func relativeLuminance(of color: UIColor) -> CGFloat {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func linearize(_ component: CGFloat) -> CGFloat {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
  }
}

// MARK: - UIColor hex helpers

extension UIColor {
  convenience init?(hex: String) {
    let hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard hexString.count == 6,
          let hexValue = UInt64(hexString, radix: 16)
    else { return nil }
    self.init(
      red: CGFloat((hexValue >> 16) & 0xFF) / 255.0,
      green: CGFloat((hexValue >> 8) & 0xFF) / 255.0,
      blue: CGFloat(hexValue & 0xFF) / 255.0,
      alpha: 1.0
    )
  }

  var hexString: String {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return String(
      format: "#%02X%02X%02X",
      Int(round(red * 255)),
      Int(round(green * 255)),
      Int(round(blue * 255))
    )
  }
}

// MARK: - UIFont theming helper

extension UIFont {
  static func themed(style: UIFont.TextStyle) -> UIFont {
    guard let family = ThemeStore.shared.fontFamily,
          ThemeStore.shared.isEnabled
    else {
      return UIFont.preferredFont(forTextStyle: style)
    }
    let systemFont = UIFont.preferredFont(forTextStyle: style)
    guard let customFont = UIFont(name: family, size: systemFont.pointSize) else {
      return systemFont
    }
    return UIFontMetrics(forTextStyle: style).scaledFont(for: customFont)
  }
}
