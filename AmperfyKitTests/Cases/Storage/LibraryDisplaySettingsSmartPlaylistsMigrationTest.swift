//
//  LibraryDisplaySettingsSmartPlaylistsMigrationTest.swift
//  AmperfyKitTests
//
//  Guards the Smart Playlists upgrade migration invariant (V1 spec, 2026-08-17):
//  settings saved before the .smartPlaylists display type existed decode with it
//  absent from BOTH inUse and notUsed, and the one-time LibrarySyncVersion.v23
//  migration re-injects it into inUse. The version-gated call site lives in
//  LibraryUpdater; this test pins the pure decode + inject behaviour it relies
//  on. Copied from LibraryDisplaySettingsGigsMigrationTest, which does the same
//  for rawValue 16.
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

// MARK: - LibraryDisplaySettingsSmartPlaylistsMigrationTest

@MainActor
class LibraryDisplaySettingsSmartPlaylistsMigrationTest: XCTestCase {
  /// A pre-smartPlaylists saved blob: inUse holds a few types, notUsed holds the
  /// rest that EXISTED at save time — critically neither list contains
  /// .smartPlaylists (rawValue 17) because that case did not yet exist. `.gigs`
  /// (16) IS present so this test isolates the new migration from the older Gigs
  /// one, and `.completeAlbums` (15) is included so the unrelated completeAlbums
  /// decode-migration is a no-op here.
  private func preSmartPlaylistsSettings() throws -> LibraryDisplaySettings {
    let json = """
    {"combined": [[0, 15, 2, 5, 16], [1, 3, 4, 6, 7, 8, 9, 10, 12, 13, 14]]}
    """
    return try JSONDecoder().decode(LibraryDisplaySettings.self, from: Data(json.utf8))
  }

  func testSmartPlaylistsAbsentFromBothListsInPreSmartPlaylistsBlob() throws {
    let settings = try preSmartPlaylistsSettings()
    let known = Set(settings.combined.flatMap { $0 })
    XCTAssertFalse(
      known.contains(.smartPlaylists),
      "pre-smartPlaylists blob must not carry the smartPlaylists case"
    )
    XCTAssertTrue(known.contains(.gigs), "the older gigs migration must already have run")
  }

  func testInjectingSmartPlaylistsPutsItInUseAndVisible() throws {
    let settings = try preSmartPlaylistsSettings()
    // Mirror the migration: append smartPlaylists to inUse and rebuild.
    var inUse = settings.inUse
    inUse.append(.smartPlaylists)
    let migrated = LibraryDisplaySettings(inUse: inUse)
    XCTAssertTrue(migrated.inUse.contains(.smartPlaylists))
    XCTAssertTrue(migrated.isVisible(libraryType: .smartPlaylists))
    XCTAssertFalse(migrated.notUsed.contains(.smartPlaylists))
  }

  func testUserRemovalIsRespectedAsSmartPlaylistsPresentInNotUsed() throws {
    // Once a user has settings where smartPlaylists lives in notUsed (a
    // deliberate removal), the migration's "absent from both" guard is false, so
    // it must NOT re-inject. This test proves the guard condition the migration
    // checks.
    let inUse: [LibraryDisplayType] = [.artists, .songs]
    let settings = LibraryDisplaySettings(inUse: inUse)
    XCTAssertTrue(
      settings.notUsed.contains(.smartPlaylists),
      "smartPlaylists computed into notUsed"
    )
    let known = Set(settings.combined.flatMap { $0 })
    XCTAssertTrue(known.contains(.smartPlaylists), "guard sees it present -> no re-inject")
  }

  func testSmartPlaylistsIsInDefaultSettings() {
    // Fresh installs never run the migration, so the default settings have to
    // carry the row themselves.
    XCTAssertTrue(LibraryDisplaySettings.defaultSettings.inUse.contains(.smartPlaylists))
  }

  func testNewestSyncVersionCoversSmartPlaylistsMigration() {
    // The LibraryUpdater block is gated on `< .v23`; if newestVersion were not
    // bumped, `isNewestVersion` would be true for a pre-migration install and
    // the blocking update would never run.
    XCTAssertEqual(LibrarySyncVersion.newestVersion, .v23)
    XCTAssertTrue(LibrarySyncVersion.v22 < LibrarySyncVersion.v23)
  }
}
