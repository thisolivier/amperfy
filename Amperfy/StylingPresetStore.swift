//
//  StylingPresetStore.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 17.5 — Styling presets).
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

import AmperfyKit
import Foundation
import UIKit

// MARK: - ModeSlice

/// One mode's (light or dark) color + gradient state, captured inside a preset.
public struct ModeSlice: Codable, Equatable, Sendable {
  public var backgroundHex: String?
  public var headingHex: String?
  public var bodyHex: String?
  public var tintHex: String?
  /// Active gradient for this mode, or nil for a solid background.
  public var gradient: ThemeGradient?

  public init(
    backgroundHex: String? = nil,
    headingHex: String? = nil,
    bodyHex: String? = nil,
    tintHex: String? = nil,
    gradient: ThemeGradient? = nil
  ) {
    self.backgroundHex = backgroundHex
    self.headingHex = headingHex
    self.bodyHex = bodyHex
    self.tintHex = tintHex
    self.gradient = gradient
  }
}

// MARK: - StylingPresetConfig

/// The full set of theming values captured by a preset (both modes + globals).
public struct StylingPresetConfig: Codable, Equatable, Sendable {
  public var fontFamily: String?
  public var borderWidthPoints: Double
  public var borderColorHex: String?
  public var light: ModeSlice
  public var dark: ModeSlice

  public init(
    fontFamily: String? = nil,
    borderWidthPoints: Double = 0,
    borderColorHex: String? = nil,
    light: ModeSlice = ModeSlice(),
    dark: ModeSlice = ModeSlice()
  ) {
    self.fontFamily = fontFamily
    self.borderWidthPoints = borderWidthPoints
    self.borderColorHex = borderColorHex
    self.light = light
    self.dark = dark
  }
}

// MARK: - StylingPreset

/// A named snapshot of the complete custom-theme state.
public struct StylingPreset: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String?
  public let createdAt: Date
  /// Schema version for forward-compatible decode. Start at 1.
  public let schemaVersion: Int
  public var config: StylingPresetConfig
  /// Stable auto-label integer burned at save time; never recomputed.
  public let autoLabelIndex: Int

  public init(
    id: UUID = UUID(),
    name: String? = nil,
    createdAt: Date = Date(),
    schemaVersion: Int = 1,
    config: StylingPresetConfig,
    autoLabelIndex: Int
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.schemaVersion = schemaVersion
    self.config = config
    self.autoLabelIndex = autoLabelIndex
  }
}

// MARK: - StylingPresetStore

/// Persistent store for user-created theme presets. Backed by a single JSON
/// blob in `UserDefaults`, same pattern as `ThemeStore`. Singleton.
public final class StylingPresetStore: @unchecked Sendable {
  public static let shared = StylingPresetStore()

  public static let didChangeNotification = Notification.Name(
    "amperfy.fork.themePresets.didChange"
  )

  private enum Key {
    static let presets = "amperfy.fork.theme.presets"
    static let autoCaptureCompleted = "amperfy.fork.theme.presets.autoCaptureCompleted"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Read

  /// All saved presets, newest-first.
  public var presets: [StylingPreset] {
    guard let storedData = defaults.data(forKey: Key.presets) else { return [] }
    let decodedPresets =
      (try? JSONDecoder().decode([StylingPreset].self, from: storedData)) ?? []
    // Apply 2-stop normalisation to any stored gradient on decode, consistent
    // with how ThemeStore.activeGradient(for:) normalises active gradients.
    return decodedPresets.map { existingPreset in
      var normalisedPreset = existingPreset
      normalisedPreset.config.light.gradient =
        existingPreset.config.light.gradient?.reducedToTwoStops()
      normalisedPreset.config.dark.gradient =
        existingPreset.config.dark.gradient?.reducedToTwoStops()
      return normalisedPreset
    }
    .sorted { $0.createdAt > $1.createdAt }
  }

  // MARK: - Write

  @discardableResult
  public func savePreset(name: String?) -> StylingPreset {
    let trimmedName = name
      .flatMap {
        $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
          .trimmingCharacters(in: .whitespaces)
      }
    let nextAutoLabelIndex = computeNextAutoLabelIndex()
    let snapshotConfig = captureCurrentThemeState()
    let newPreset = StylingPreset(
      name: trimmedName,
      createdAt: Date(),
      config: snapshotConfig,
      autoLabelIndex: nextAutoLabelIndex
    )
    var updatedPresets = presets
    updatedPresets.append(newPreset)
    persistPresets(updatedPresets)
    postDidChangeNotification()
    return newPreset
  }

  /// Applies every field of the preset back into ThemeStore, then fires
  /// ThemeStore.postChangeNotification ONCE (avoids per-field flicker).
  public func loadFullPreset(_ preset: StylingPreset) {
    loadFullPresetInto(preset: preset, themeStore: ThemeStore.shared)
    ThemeStore.shared.postChangeNotification()
  }

  /// Testable variant — writes into the given ThemeStore without posting a
  /// notification. Tests use this to avoid touching shared singletons.
  func loadFullPresetInto(preset: StylingPreset, themeStore: ThemeStore) {
    applyModeSlice(preset.config.light, toThemeStore: themeStore, style: .light)
    applyModeSlice(preset.config.dark, toThemeStore: themeStore, style: .dark)
    applyGlobals(preset.config, toThemeStore: themeStore)
  }

  /// Applies only light-mode colors + light gradient from the preset.
  /// Globals (font, border) and dark-mode state are left unchanged.
  public func loadLightSlice(from preset: StylingPreset) {
    loadLightSliceInto(preset: preset, themeStore: ThemeStore.shared)
    ThemeStore.shared.postChangeNotification()
  }

  /// Testable variant for loadLightSlice.
  func loadLightSliceInto(preset: StylingPreset, themeStore: ThemeStore) {
    applyModeSlice(preset.config.light, toThemeStore: themeStore, style: .light)
  }

  /// Applies only dark-mode colors + dark gradient from the preset.
  /// Globals (font, border) and light-mode state are left unchanged.
  public func loadDarkSlice(from preset: StylingPreset) {
    loadDarkSliceInto(preset: preset, themeStore: ThemeStore.shared)
    ThemeStore.shared.postChangeNotification()
  }

  /// Testable variant for loadDarkSlice.
  func loadDarkSliceInto(preset: StylingPreset, themeStore: ThemeStore) {
    applyModeSlice(preset.config.dark, toThemeStore: themeStore, style: .dark)
  }

  /// Updates the preset's name in the list. Empty string reverts to auto-label (nil).
  public func renamePreset(_ preset: StylingPreset, to newName: String?) {
    let trimmedName = newName.flatMap {
      $0.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil
        : $0.trimmingCharacters(in: .whitespaces)
    }
    var updatedPresets = presets
    guard let targetIndex = updatedPresets.firstIndex(where: { $0.id == preset.id }) else {
      return
    }
    updatedPresets[targetIndex].name = trimmedName
    persistPresets(updatedPresets)
    postDidChangeNotification()
  }

  /// Removes the preset with the matching id.
  public func deletePreset(_ preset: StylingPreset) {
    let filteredPresets = presets.filter { $0.id != preset.id }
    persistPresets(filteredPresets)
    postDidChangeNotification()
  }

  /// Returns the user-given name, or a stable auto-label like "Preset 3".
  public func displayName(for preset: StylingPreset) -> String {
    if let userName = preset.name, !userName.isEmpty {
      return userName
    }
    return "Preset \(preset.autoLabelIndex)"
  }

  // MARK: - Auto-capture

  /// Called once at startup. If this is the first Release-5 launch AND the
  /// user has a configured custom theme, saves "My Theme (auto-saved)" as a
  /// safety-net preset. The one-shot flag prevents a repeat on subsequent
  /// launches.
  public func performAutoCaptureIfNeeded() {
    guard !defaults.bool(forKey: Key.autoCaptureCompleted) else { return }
    // Mark as completed unconditionally so we never re-run, even if the
    // theme is disabled or the user hasn't customised anything.
    defaults.set(true, forKey: Key.autoCaptureCompleted)

    let themeStore = ThemeStore.shared
    guard themeStore.isEnabled else { return }
    guard hasAnyNonDefaultField(in: themeStore) else { return }
    savePreset(name: "My Theme (auto-saved)")
  }

  // MARK: - Private helpers

  private func captureCurrentThemeState() -> StylingPresetConfig {
    let themeStore = ThemeStore.shared
    let lightSlice = ModeSlice(
      backgroundHex: themeStore.lightBackground?.hexString,
      headingHex: themeStore.lightHeadingText?.hexString,
      bodyHex: themeStore.lightText?.hexString,
      tintHex: themeStore.lightTint?.hexString,
      gradient: themeStore.activeGradient(for: .light)
    )
    let darkSlice = ModeSlice(
      backgroundHex: themeStore.darkBackground?.hexString,
      headingHex: themeStore.darkHeadingText?.hexString,
      bodyHex: themeStore.darkText?.hexString,
      tintHex: themeStore.darkTint?.hexString,
      gradient: themeStore.activeGradient(for: .dark)
    )
    return StylingPresetConfig(
      fontFamily: themeStore.fontFamily,
      borderWidthPoints: Double(themeStore.albumArtBorderWidth),
      borderColorHex: themeStore.albumArtBorderColor?.hexString,
      light: lightSlice,
      dark: darkSlice
    )
  }

  private func applyModeSlice(
    _ modeSlice: ModeSlice,
    toThemeStore themeStore: ThemeStore,
    style: UIUserInterfaceStyle
  ) {
    let isDark = style == .dark
    if let hexValue = modeSlice.backgroundHex {
      if isDark { themeStore.darkBackground = UIColor(hex: hexValue) }
      else { themeStore.lightBackground = UIColor(hex: hexValue) }
    }
    if let hexValue = modeSlice.headingHex {
      if isDark { themeStore.darkHeadingText = UIColor(hex: hexValue) }
      else { themeStore.lightHeadingText = UIColor(hex: hexValue) }
    }
    if let hexValue = modeSlice.bodyHex {
      if isDark { themeStore.darkText = UIColor(hex: hexValue) }
      else { themeStore.lightText = UIColor(hex: hexValue) }
    }
    if let hexValue = modeSlice.tintHex {
      if isDark { themeStore.darkTint = UIColor(hex: hexValue) }
      else { themeStore.lightTint = UIColor(hex: hexValue) }
    }
    themeStore.setActiveGradient(modeSlice.gradient, for: style)
  }

  private func applyGlobals(_ config: StylingPresetConfig, toThemeStore themeStore: ThemeStore) {
    themeStore.fontFamily = config.fontFamily
    themeStore.albumArtBorderWidth = CGFloat(config.borderWidthPoints)
    if let hexValue = config.borderColorHex {
      themeStore.albumArtBorderColor = UIColor(hex: hexValue)
    } else {
      themeStore.albumArtBorderColor = nil
    }
  }

  /// Preview of the auto-label integer that would be assigned if a preset were
  /// saved right now. Exposed so save-alert placeholders can stay consistent
  /// with what `savePreset(name: nil)` will actually store.
  public var nextAutoLabelIndex: Int {
    computeNextAutoLabelIndex()
  }

  private func computeNextAutoLabelIndex() -> Int {
    let existingIndices = presets.map { $0.autoLabelIndex }
    return (existingIndices.max() ?? 0) + 1
  }

  private func persistPresets(_ presetsToStore: [StylingPreset]) {
    if presetsToStore.isEmpty {
      defaults.removeObject(forKey: Key.presets)
      return
    }
    if let encodedData = try? JSONEncoder().encode(presetsToStore) {
      defaults.set(encodedData, forKey: Key.presets)
    }
  }

  private func postDidChangeNotification() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func hasAnyNonDefaultField(in themeStore: ThemeStore) -> Bool {
    themeStore.lightBackground != nil
      || themeStore.lightText != nil
      || themeStore.lightHeadingText != nil
      || themeStore.lightTint != nil
      || themeStore.darkBackground != nil
      || themeStore.darkText != nil
      || themeStore.darkHeadingText != nil
      || themeStore.darkTint != nil
      || themeStore.fontFamily != nil
      || themeStore.albumArtBorderWidth > 0
      || themeStore.albumArtBorderColor != nil
      || themeStore.activeGradient(for: .light) != nil
      || themeStore.activeGradient(for: .dark) != nil
  }
}
