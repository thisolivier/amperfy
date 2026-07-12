//
//  RecentTracksFilterSettingsTest.swift
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

/// Persistence tests for the Recently Added triage-filter toggle.
class RecentTracksFilterSettingsTest: XCTestCase {
  var defaults: UserDefaults!
  var settings: RecentTracksFilterSettings!

  override func setUp() {
    defaults = UserDefaults(suiteName: "RecentTracksFilterSettingsTest-\(UUID().uuidString)")
    settings = RecentTracksFilterSettings(defaults: defaults)
  }

  /// Opt-in default: the filter is off until the user enables it, so upgrading
  /// users see the unchanged, unfiltered list.
  func testDefaultsToOffWhenUnset() {
    XCTAssertFalse(settings.hideSongsInPlaylists)
  }

  /// The toggle persists and a fresh instance over the same store sees it.
  func testStoresAndRetrievesEnabledState() {
    settings.hideSongsInPlaylists = true
    XCTAssertTrue(settings.hideSongsInPlaylists)

    let reloaded = RecentTracksFilterSettings(defaults: defaults)
    XCTAssertTrue(
      reloaded.hideSongsInPlaylists,
      "A fresh instance must read the persisted enabled state"
    )
  }

  /// Toggling back off persists too.
  func testTogglingBackOffPersists() {
    settings.hideSongsInPlaylists = true
    settings.hideSongsInPlaylists = false

    let reloaded = RecentTracksFilterSettings(defaults: defaults)
    XCTAssertFalse(reloaded.hideSongsInPlaylists)
  }

  /// The persisted key is the fork-namespaced one, so it does not collide with
  /// the pre-existing mode/count keys.
  func testUsesForkNamespacedKey() {
    settings.hideSongsInPlaylists = true
    XCTAssertTrue(
      defaults.bool(forKey: "amperfy.fork.recentTracks.hideSongsInPlaylists")
    )
  }

  // MARK: - Filter caption (B2)

  /// No caption at all when the filter is off (no toast anywhere either).
  func testCaptionIsNilWhenFilterOff() {
    XCTAssertNil(
      RecentTracksFilterCaption.text(hideSongsInPlaylists: false, visibleCount: 12)
    )
  }

  /// When the filter is on, the caption reads "Filtered · N unfiled" with N the
  /// current visible count.
  func testCaptionFormatAndCountWhenFilterOn() {
    XCTAssertEqual(
      RecentTracksFilterCaption.text(hideSongsInPlaylists: true, visibleCount: 12),
      "Filtered · 12 unfiled"
    )
  }

  /// The count is live — a different visible count yields a different caption.
  func testCaptionCountIsLive() {
    XCTAssertEqual(
      RecentTracksFilterCaption.text(hideSongsInPlaylists: true, visibleCount: 1),
      "Filtered · 1 unfiled"
    )
    XCTAssertEqual(
      RecentTracksFilterCaption.text(hideSongsInPlaylists: true, visibleCount: 0),
      "Filtered · 0 unfiled"
    )
  }
}
