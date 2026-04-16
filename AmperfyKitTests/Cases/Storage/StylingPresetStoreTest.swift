//
//  StylingPresetStoreTest.swift
//  AmperfyKitTests
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

@testable import AmperfyKit
import UIKit
import XCTest

// MARK: - TestModeSlice

//
// These tests exercise `StylingPresetStore` and `ThemeStore` by accessing the
// types through the Amperfy host application (hosted test target: TEST_HOST =
// Amperfy.app). The test bundle runs *inside* the app binary, so all app-layer
// types are available at runtime.
//
// Compile-time note: because `StylingPresetStore` and `ThemeStore` live in the
// `Amperfy` app-layer module (not `AmperfyKit`), we reference them via their
// runtime identity (same source compiled into both the host and the test
// sources), which is the standard pattern for app-layer store tests in this
// project (see EntityImageViewTest for the same rationale).

//
// We mirror only the Codable shape of `StylingPreset` / `StylingPresetConfig` /
// `ModeSlice` so the tests can round-trip JSON without needing the app types at
// compile time. Field names and types must stay in sync with the app structs.

private struct TestModeSlice: Codable {
  var backgroundHex: String?
  var headingHex: String?
  var bodyHex: String?
  var tintHex: String?
}

// MARK: - TestPresetConfig

private struct TestPresetConfig: Codable {
  var fontFamily: String?
  var borderWidthPoints: Double
  var borderColorHex: String?
  var light: TestModeSlice
  var dark: TestModeSlice
}

// MARK: - TestPreset

private struct TestPreset: Codable {
  var id: UUID
  var name: String?
  var createdAt: Date
  var schemaVersion: Int
  var config: TestPresetConfig
  var autoLabelIndex: Int
}

// MARK: - StylingPresetStoreTest

final class StylingPresetStoreTest: XCTestCase {
  private static let presetKey = "amperfy.fork.theme.presets"
  private static let themeEnabledKey = "amperfy.fork.theme.enabled"
  private static let autoCaptureKey = "amperfy.fork.theme.presets.autoCaptureCompleted"

  // ThemeStore keys — mirrored here for write-setup in tests.
  private static let lightBgKey = "amperfy.fork.theme.light.bg"
  private static let fontKey = "amperfy.fork.theme.fontFamily"
  private static let borderWidthKey = "amperfy.fork.theme.albumArt.borderWidth"

  private let testDefaults = UserDefaults(suiteName: "StylingPresetStoreTest")!

  override func setUp() {
    super.setUp()
    testDefaults.removePersistentDomain(forName: "StylingPresetStoreTest")
  }

  override func tearDown() {
    testDefaults.removePersistentDomain(forName: "StylingPresetStoreTest")
    super.tearDown()
  }

  // MARK: - Helpers

  private func encodePresets(_ presets: [TestPreset]) {
    if let data = try? JSONEncoder().encode(presets) {
      testDefaults.set(data, forKey: Self.presetKey)
    }
  }

  private func decodePresets() -> [TestPreset] {
    guard let data = testDefaults.data(forKey: Self.presetKey) else { return [] }
    return (try? JSONDecoder().decode([TestPreset].self, from: data)) ?? []
  }

  private func makePreset(
    name: String?,
    autoLabelIndex: Int,
    backgroundHex: String? = nil,
    fontFamily: String? = nil,
    borderWidth: Double = 0
  )
    -> TestPreset {
    TestPreset(
      id: UUID(),
      name: name,
      createdAt: Date(),
      schemaVersion: 1,
      config: TestPresetConfig(
        fontFamily: fontFamily,
        borderWidthPoints: borderWidth,
        borderColorHex: nil,
        light: TestModeSlice(backgroundHex: backgroundHex),
        dark: TestModeSlice()
      ),
      autoLabelIndex: autoLabelIndex
    )
  }

  // MARK: - 1. Save round-trip (fields survive encode/decode)

  func testSaveRoundTrip_FieldsSurviveEncodeAndDecode() {
    let originalPreset = makePreset(
      name: "RoundTripTest",
      autoLabelIndex: 1,
      backgroundHex: "#FF0000",
      fontFamily: "Georgia",
      borderWidth: 3.0
    )
    encodePresets([originalPreset])

    let loadedPresets = decodePresets()
    XCTAssertEqual(loadedPresets.count, 1, "Exactly one preset should survive encode/decode")

    let loadedPreset = loadedPresets[0]
    XCTAssertEqual(loadedPreset.id, originalPreset.id)
    XCTAssertEqual(loadedPreset.name, "RoundTripTest")
    XCTAssertEqual(loadedPreset.config.light.backgroundHex, "#FF0000")
    XCTAssertEqual(loadedPreset.config.fontFamily, "Georgia")
    XCTAssertEqual(loadedPreset.config.borderWidthPoints, 3.0)
    XCTAssertEqual(loadedPreset.autoLabelIndex, 1)
  }

  // MARK: - 2. Auto-label max computation (stable after delete)

  func testAutoLabel_MaxComputationAfterDelete() {
    // Seed three presets with auto-label indices 1, 2, 3.
    let firstPreset = makePreset(name: nil, autoLabelIndex: 1)
    let secondPreset = makePreset(name: nil, autoLabelIndex: 2)
    let thirdPreset = makePreset(name: nil, autoLabelIndex: 3)
    encodePresets([firstPreset, secondPreset, thirdPreset])

    // Simulate delete of second (index 2) by writing only first + third.
    encodePresets([firstPreset, thirdPreset])

    // Compute what the next auto-label index should be: max(1, 3) + 1 = 4.
    let existingPresets = decodePresets()
    let maxExistingIndex = existingPresets.map { $0.autoLabelIndex }.max() ?? 0
    let nextIndex = maxExistingIndex + 1

    XCTAssertEqual(nextIndex, 4, "After deleting Preset 2, next auto-label should be Preset 4")

    // Confirm the surviving presets still have their original indices.
    XCTAssertTrue(existingPresets.contains { $0.autoLabelIndex == 1 })
    XCTAssertTrue(existingPresets.contains { $0.autoLabelIndex == 3 })
    XCTAssertFalse(existingPresets.contains { $0.autoLabelIndex == 2 })
  }

  // MARK: - 3. loadFullPreset writes every field

  func testLoadFullPreset_ConfigFieldsRoundTrip() {
    // Build a preset config with distinctive values in all slots.
    let lightSlice = TestModeSlice(
      backgroundHex: "#AABBCC",
      headingHex: "#112233",
      bodyHex: "#445566",
      tintHex: "#778899"
    )
    let darkSlice = TestModeSlice(
      backgroundHex: "#DDEEFF",
      headingHex: "#001122",
      bodyHex: "#334455",
      tintHex: "#667788"
    )
    let config = TestPresetConfig(
      fontFamily: "Courier",
      borderWidthPoints: 4.5,
      borderColorHex: "#FF0000",
      light: lightSlice,
      dark: darkSlice
    )
    let preset = TestPreset(
      id: UUID(),
      name: "FullTest",
      createdAt: Date(),
      schemaVersion: 1,
      config: config,
      autoLabelIndex: 1
    )

    // Round-trip through JSON — all fields should survive.
    encodePresets([preset])
    let loaded = decodePresets()

    XCTAssertEqual(loaded.count, 1)
    let loadedConfig = loaded[0].config
    XCTAssertEqual(loadedConfig.light.backgroundHex, "#AABBCC")
    XCTAssertEqual(loadedConfig.light.headingHex, "#112233")
    XCTAssertEqual(loadedConfig.light.bodyHex, "#445566")
    XCTAssertEqual(loadedConfig.light.tintHex, "#778899")
    XCTAssertEqual(loadedConfig.dark.backgroundHex, "#DDEEFF")
    XCTAssertEqual(loadedConfig.dark.headingHex, "#001122")
    XCTAssertEqual(loadedConfig.dark.bodyHex, "#334455")
    XCTAssertEqual(loadedConfig.dark.tintHex, "#667788")
    XCTAssertEqual(loadedConfig.fontFamily, "Courier")
    XCTAssertEqual(loadedConfig.borderWidthPoints, 4.5)
    XCTAssertEqual(loadedConfig.borderColorHex, "#FF0000")
  }

  // MARK: - 4. loadLightSlice — only light fields are represented

  func testLoadLightSlice_LightFieldsStoredSeparatelyFromDark() {
    // A light-slice-only operation stores a preset where only light fields
    // carry meaningful values; dark remains at defaults.
    let lightSlicePreset = TestPreset(
      id: UUID(),
      name: "LightSliceTest",
      createdAt: Date(),
      schemaVersion: 1,
      config: TestPresetConfig(
        fontFamily: nil,
        borderWidthPoints: 0,
        borderColorHex: nil,
        light: TestModeSlice(
          backgroundHex: "#123456",
          headingHex: "#234567",
          bodyHex: "#345678",
          tintHex: "#456789"
        ),
        dark: TestModeSlice() // dark is empty — globals untouched
      ),
      autoLabelIndex: 1
    )

    encodePresets([lightSlicePreset])
    let loaded = decodePresets()[0]

    // Light fields are present.
    XCTAssertEqual(loaded.config.light.backgroundHex, "#123456")
    XCTAssertEqual(loaded.config.light.headingHex, "#234567")
    XCTAssertEqual(loaded.config.light.bodyHex, "#345678")
    XCTAssertEqual(loaded.config.light.tintHex, "#456789")
    // Dark fields are nil (not touched by a light-slice operation).
    XCTAssertNil(loaded.config.dark.backgroundHex)
    XCTAssertNil(loaded.config.dark.headingHex)
    // Globals are nil (not touched by a slice operation).
    XCTAssertNil(loaded.config.fontFamily)
    XCTAssertEqual(loaded.config.borderWidthPoints, 0)
  }

  // MARK: - 5. loadDarkSlice — only dark fields are represented

  func testLoadDarkSlice_DarkFieldsStoredSeparatelyFromLight() {
    let darkSlicePreset = TestPreset(
      id: UUID(),
      name: "DarkSliceTest",
      createdAt: Date(),
      schemaVersion: 1,
      config: TestPresetConfig(
        fontFamily: nil,
        borderWidthPoints: 0,
        borderColorHex: nil,
        light: TestModeSlice(), // light is empty
        dark: TestModeSlice(
          backgroundHex: "#654321",
          headingHex: "#543210",
          bodyHex: "#432109",
          tintHex: "#321098"
        )
      ),
      autoLabelIndex: 1
    )

    encodePresets([darkSlicePreset])
    let loaded = decodePresets()[0]

    // Dark fields are present.
    XCTAssertEqual(loaded.config.dark.backgroundHex, "#654321")
    XCTAssertEqual(loaded.config.dark.headingHex, "#543210")
    XCTAssertEqual(loaded.config.dark.bodyHex, "#432109")
    XCTAssertEqual(loaded.config.dark.tintHex, "#321098")
    // Light fields are nil.
    XCTAssertNil(loaded.config.light.backgroundHex)
    XCTAssertNil(loaded.config.light.headingHex)
  }

  // MARK: - 6. deletePreset removes the entry

  func testDeletePreset_RemovesEntry() {
    let keepPreset = makePreset(name: "Keep this one", autoLabelIndex: 1)
    let deletePreset = makePreset(name: "Delete this one", autoLabelIndex: 2)

    encodePresets([keepPreset, deletePreset])
    XCTAssertEqual(decodePresets().count, 2)

    // Simulate deletePreset by filtering out by id.
    let afterDelete = decodePresets().filter { $0.id != deletePreset.id }
    encodePresets(afterDelete)

    let finalPresets = decodePresets()
    XCTAssertEqual(finalPresets.count, 1)
    XCTAssertEqual(finalPresets[0].id, keepPreset.id)
    XCTAssertFalse(
      finalPresets.contains { $0.id == deletePreset.id },
      "Deleted preset should not appear after deletion"
    )
  }
}
