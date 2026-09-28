//
//  NavidromeCanonicalIdTest.swift
//  AmperfyKitTests
//
//  Created for the 2026-09-28 server id migration (upstream canonical ids).
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

class NavidromeCanonicalIdTest: XCTestCase {
  /// Real (old, new) pairs extracted from the PRODUCTION database before and
  /// after the server's actual canonical-id migration — the transform must
  /// match Go's output byte-for-byte or relinked downloads point at nothing.
  func testMatchesRealServerMigrationOutput() {
    let realMigrationPairs: [(old: String, new: String)] = [
      ("8pguTfxljziMdXk0MqeLFq", "0ZT5OhIog2Au1AbrnNyZvR"),
      ("SZh7lvaVtDbTnTmZs8SHRc", "1xIzo9PdboY9n8uteC3u02"),
      ("ULbu3tBwqquPjN7HDYs83U", "1oIIW0CzmHLtxUeGm1mo39"),
      ("TX9XVgmugIXSFeW249emKm", "3WOiqFQRFBEHHoCVklRVjM"),
      ("BGnZZIFspA8xpSThL9wo3j", "3Uoi7xzYREPGnCNORbfDUe"),
      ("zusZBNQ7Wnsxzvf2S4ueHM", "4JW5wmB6XGSTsg4sHkduwp"),
    ]
    for pair in realMigrationPairs {
      XCTAssertEqual(
        NavidromeCanonicalId.canonicalized(pair.old), pair.new,
        "Transform must reproduce the server migration exactly for \(pair.old)"
      )
    }
  }

  func testIdsTheMigrationKeepsPassThrough() {
    // Fits 128 bits (upstream's own hash-family example) — kept verbatim.
    XCTAssertEqual(
      NavidromeCanonicalId.canonicalized("5cLJPkLA5DK2BADhoeotPk"),
      "5cLJPkLA5DK2BADhoeotPk"
    )
    // Wrong lengths and shapes pass through untouched.
    XCTAssertEqual(NavidromeCanonicalId.canonicalized(""), "")
    XCTAssertEqual(NavidromeCanonicalId.canonicalized("short"), "short")
    let uuid = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    XCTAssertEqual(NavidromeCanonicalId.canonicalized(uuid), uuid)
    // 22 chars containing a non-base62 character passes through.
    XCTAssertEqual(
      NavidromeCanonicalId.canonicalized("!!!!!!!!!!!!!!!!!!!!!!"),
      "!!!!!!!!!!!!!!!!!!!!!!"
    )
    // The transform is a fixed point: re-encoded output fits 128 bits.
    let remapped = NavidromeCanonicalId.canonicalized("zusZBNQ7Wnsxzvf2S4ueHM")
    XCTAssertEqual(NavidromeCanonicalId.canonicalized(remapped), remapped)
  }

  func testRelinkRenamesOnlyOverflowingIdFiles() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("canonical-relink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let overflowingId = "zusZBNQ7Wnsxzvf2S4ueHM" // real pair above
    let keptId = "5cLJPkLA5DK2BADhoeotPk"
    FileManager.default.createFile(
      atPath: directoryURL.appendingPathComponent("\(overflowingId).flac").path,
      contents: Data("audio".utf8)
    )
    FileManager.default.createFile(
      atPath: directoryURL.appendingPathComponent("\(keptId).mp3").path,
      contents: Data("audio2".utf8)
    )

    let renamedCount = NavidromeCanonicalId.relinkFiles(in: directoryURL)

    XCTAssertEqual(renamedCount, 1)
    let remainingFiles = try FileManager.default
      .contentsOfDirectory(atPath: directoryURL.path).sorted()
    XCTAssertEqual(
      remainingFiles,
      ["4JW5wmB6XGSTsg4sHkduwp.flac", "\(keptId).mp3"].sorted(),
      "Only the overflowing id is renamed; content preserved under the new id"
    )
    let renamedData = FileManager.default.contents(
      atPath: directoryURL.appendingPathComponent("4JW5wmB6XGSTsg4sHkduwp.flac").path
    )
    XCTAssertEqual(renamedData, Data("audio".utf8))
  }
}
