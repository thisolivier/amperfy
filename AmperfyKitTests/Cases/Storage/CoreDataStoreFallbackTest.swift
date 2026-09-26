//
//  CoreDataStoreFallbackTest.swift
//  AmperfyKitTests
//
//  Created for the Mac startup-crash fix (shared App Group container fallback).
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

@MainActor
class CoreDataStoreFallbackTest: XCTestCase {
  func testWritableDirectoryPassesProbe() {
    let writableDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("amperfy-probe-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: writableDirectory) }

    XCTAssertTrue(CoreDataPersistentManager.isDirectoryWritable(at: writableDirectory))
    // The probe must not leave its temp file behind
    let leftovers = (try? FileManager.default.contentsOfDirectory(
      atPath: writableDirectory.path
    )) ?? []
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testProbeCreatesMissingIntermediateDirectories() {
    let nestedDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("amperfy-probe-test-\(UUID().uuidString)")
      .appendingPathComponent("nested/deeper")
    defer {
      try? FileManager.default.removeItem(
        at: nestedDirectory.deletingLastPathComponent().deletingLastPathComponent()
      )
    }

    XCTAssertTrue(CoreDataPersistentManager.isDirectoryWritable(at: nestedDirectory))
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: nestedDirectory.path, isDirectory: &isDirectory
    ))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testUnwritableDirectoryFailsProbe() {
    // SIP-protected location — createDirectory must fail even when unsandboxed
    let unwritableDirectory = URL(fileURLWithPath: "/System/Library")
      .appendingPathComponent("amperfy-probe-test-\(UUID().uuidString)")

    XCTAssertFalse(CoreDataPersistentManager.isDirectoryWritable(at: unwritableDirectory))
  }

  func testManagerWithoutSharedContainerUsesDefaultStoreLocation() {
    let configuration = CoreDataConfiguration()

    XCTAssertNil(configuration.sharedContainerURL)
    XCTAssertNil(configuration.sharedStoreURL)
  }
}
