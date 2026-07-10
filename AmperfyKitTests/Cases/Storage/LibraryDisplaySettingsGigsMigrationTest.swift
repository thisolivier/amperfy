//
//  LibraryDisplaySettingsGigsMigrationTest.swift
//  AmperfyKitTests
//
//  Guards the Gigs-tab upgrade migration invariant (QA A-P2-3): settings saved
//  before the .gigs display type existed decode with gigs absent from BOTH
//  inUse and notUsed, and the one-time migration re-injects it into inUse. The
//  version-gated call site lives in LibraryUpdater; this test pins the pure
//  decode + inject behaviour the migration relies on.
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

// MARK: - LibraryDisplaySettingsGigsMigrationTest

@MainActor
class LibraryDisplaySettingsGigsMigrationTest: XCTestCase {
  /// A pre-gigs saved blob: inUse holds a few types, notUsed holds the rest that
  /// EXISTED at save time — critically neither list contains .gigs (rawValue 16)
  /// because that case did not yet exist. `.completeAlbums` (15) is included so
  /// the unrelated completeAlbums decode-migration is a no-op here.
  private func preGigsSettings() throws -> LibraryDisplaySettings {
    let json = """
    {"combined": [[0, 15, 2, 5], [1, 3, 4, 6, 7, 8, 9, 10, 12, 13, 14]]}
    """
    return try JSONDecoder().decode(LibraryDisplaySettings.self, from: Data(json.utf8))
  }

  func testGigsAbsentFromBothListsInPreGigsBlob() throws {
    let settings = try preGigsSettings()
    let known = Set(settings.combined.flatMap { $0 })
    XCTAssertFalse(known.contains(.gigs), "pre-gigs blob must not carry the gigs case")
  }

  func testInjectingGigsPutsItInUseAndVisible() throws {
    let settings = try preGigsSettings()
    // Mirror the migration: append gigs to inUse and rebuild.
    var inUse = settings.inUse
    inUse.append(.gigs)
    let migrated = LibraryDisplaySettings(inUse: inUse)
    XCTAssertTrue(migrated.inUse.contains(.gigs))
    XCTAssertTrue(migrated.isVisible(libraryType: .gigs))
    XCTAssertFalse(migrated.notUsed.contains(.gigs))
  }

  func testUserRemovalIsRespectedAsGigsPresentInNotUsed() throws {
    // Once a user has settings where gigs lives in notUsed (a deliberate
    // removal), the migration's "absent from both" guard is false, so it must
    // NOT re-inject. This test proves the guard condition the migration checks.
    let inUse: [LibraryDisplayType] = [.artists, .songs]
    let settings = LibraryDisplaySettings(inUse: inUse)
    XCTAssertTrue(settings.notUsed.contains(.gigs), "gigs computed into notUsed")
    let known = Set(settings.combined.flatMap { $0 })
    XCTAssertTrue(known.contains(.gigs), "guard sees gigs present -> no re-inject")
  }
}
