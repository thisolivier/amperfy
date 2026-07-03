//
//  AdjacencySidecarSettingsTest.swift
//  AmperfyKitTests
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

@testable import AmperfyKit
import XCTest

class AdjacencySidecarSettingsTest: XCTestCase {
  var defaults: UserDefaults!
  var settings: AdjacencySidecarSettings!

  override func setUp() {
    defaults = UserDefaults(suiteName: "AdjacencySidecarSettingsTest-\(UUID().uuidString)")
    settings = AdjacencySidecarSettings(defaults: defaults)
  }

  func testDefaultsTo8787WhenUnset() {
    XCTAssertEqual(settings.port, 8787)
  }

  func testStoresAndRetrievesCustomPort() {
    settings.port = 8788
    XCTAssertEqual(settings.port, 8788)

    // A fresh instance over the same UserDefaults should see the stored value.
    let reloaded = AdjacencySidecarSettings(defaults: defaults)
    XCTAssertEqual(reloaded.port, 8788)
  }
}
