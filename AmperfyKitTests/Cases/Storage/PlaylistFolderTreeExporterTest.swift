//
//  PlaylistFolderTreeExporterTest.swift
//  AmperfyKitTests
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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
import CoreData
import XCTest

/// Tests for the JSON safety net written after every folder mutation.
///
/// The 2026-08-02 loss was unrecoverable because the folder tree existed only in
/// an app-private SQLite store and on a server that had just lost it. These tests
/// pin the two properties that make the export a real fallback: it round-trips,
/// and it is keyed on playlist *names*, which survive the id churn a resync or
/// reinstall causes.
@MainActor
class PlaylistFolderTreeExporterTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!
  private var exportDirectoryURL: URL!
  private var exporter: PlaylistFolderTreeExporter!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    exportDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PlaylistFolderTreeExporterTest-\(UUID().uuidString)")
    exporter = PlaylistFolderTreeExporter(exportDirectoryURL: exportDirectoryURL)
    store = PlaylistFolderStore(
      defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!,
      treeExporter: exporter
    )
    store.configureForTesting(context: testContext, account: account.managedObject)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: exportDirectoryURL)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  @discardableResult
  private func seedLocalPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    try? testContext.save()
    return playlist
  }

  private func sampleExport() -> PlaylistFolderTreeExport {
    PlaylistFolderTreeExport(
      exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
      folders: [
        PlaylistFolderExportFolder(
          id: "folder-rock", name: "Rock", parentId: "", sortOrder: 10
        ),
        PlaylistFolderExportFolder(
          id: "folder-metal", name: "Metal", parentId: "folder-rock", sortOrder: nil
        ),
      ],
      placements: [
        PlaylistFolderExportPlacement(
          playlistName: "Riffs", playlistId: "pl-1", folderId: "folder-rock", sortOrder: 10
        ),
        PlaylistFolderExportPlacement(
          playlistName: "Solos", playlistId: "pl-2", folderId: "", sortOrder: nil
        ),
      ]
    )
  }

  // MARK: - Round trip

  func testWriteThenReadRoundTripsExactly() throws {
    let export = sampleExport()
    try exporter.write(export)

    let readBack = try exporter.readCurrent()
    XCTAssertEqual(readBack, export)
  }

  func testWriteCreatesTheExportDirectory() throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectoryURL.path))
    try exporter.write(sampleExport())
    XCTAssertTrue(FileManager.default.fileExists(atPath: exporter.currentFileURL.path))
  }

  /// The file is meant to be opened by a human in the Files app, so it has to be
  /// legible JSON carrying names, not just ids.
  func testExportedJsonIsReadableAndCarriesPlaylistNames() throws {
    try exporter.write(sampleExport())
    let rawJson = try String(contentsOf: exporter.currentFileURL, encoding: .utf8)

    XCTAssertTrue(rawJson.contains("\"playlistName\" : \"Riffs\""))
    XCTAssertTrue(rawJson.contains("\"name\" : \"Rock\""))
    XCTAssertTrue(rawJson.contains("\"exportFormatVersion\""))
    XCTAssertTrue(rawJson.contains("\n"), "Export should be pretty-printed")
  }

  // MARK: - Rolling

  func testSecondWriteRollsThePreviousGenerationAside() throws {
    let firstExport = sampleExport()
    try exporter.write(firstExport)

    let secondExport = PlaylistFolderTreeExport(
      exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
      folders: [],
      placements: []
    )
    try exporter.write(secondExport)

    XCTAssertEqual(try exporter.readCurrent(), secondExport)
    XCTAssertEqual(
      try exporter.readPrevious(), firstExport,
      "The last good snapshot must survive a write made against damaged state"
    )
  }

  func testOnlyOnePreviousGenerationIsKept() throws {
    let firstExport = sampleExport()
    try exporter.write(firstExport)
    let secondExport = PlaylistFolderTreeExport(
      exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
      folders: [],
      placements: []
    )
    try exporter.write(secondExport)
    let thirdExport = PlaylistFolderTreeExport(
      exportedAt: Date(timeIntervalSince1970: 1_800_000_200),
      folders: [],
      placements: []
    )
    try exporter.write(thirdExport)

    XCTAssertEqual(try exporter.readCurrent(), thirdExport)
    XCTAssertEqual(try exporter.readPrevious(), secondExport)
  }

  func testFirstWriteLeavesNoPreviousFile() throws {
    try exporter.write(sampleExport())
    XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.previousFileURL.path))
  }

  // MARK: - Written from real store state

  func testMutatingTheStoreWritesASnapshotOfTheWholeTree() throws {
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["pl-1"], to: folder.id)

    let export = try exporter.readCurrent()
    XCTAssertEqual(export.folders.map(\.name), ["Rock"])
    XCTAssertEqual(export.placements.count, 1)

    let placement = try XCTUnwrap(export.placements.first)
    XCTAssertEqual(placement.playlistName, "Riffs")
    XCTAssertEqual(placement.playlistId, "pl-1")
    XCTAssertEqual(placement.sortOrder, 10)
  }

  /// Names are the durable key: the same organization must still be legible from
  /// the file after every server id has changed underneath it.
  func testSnapshotRemainsLegibleAfterServerIdChurn() throws {
    seedLocalPlaylist(id: "old-server-id", name: "Riffs")
    let folder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["old-server-id"], to: folder.id)

    let exportBefore = try exporter.readCurrent()
    let placementBefore = try XCTUnwrap(exportBefore.placements.first)

    // Simulate a resync handing the same playlist a brand new id.
    let playlistMO = try XCTUnwrap(
      library.getPlaylists(for: account).first { $0.id == "old-server-id" }
    )
    playlistMO.id = "new-server-id"
    try? testContext.save()
    store.renameFolder(id: folder.id, to: "Rock")

    let exportAfter = try exporter.readCurrent()
    let placementAfter = try XCTUnwrap(exportAfter.placements.first)

    XCTAssertEqual(placementBefore.playlistName, placementAfter.playlistName)
    XCTAssertNotEqual(placementBefore.playlistId, placementAfter.playlistId)
  }

  func testExportFailureNeverPropagates() {
    // A path that cannot be created: writing must be swallowed and logged.
    let unwritableExporter = PlaylistFolderTreeExporter(
      exportDirectoryURL: URL(fileURLWithPath: "/dev/null/nope")
    )
    unwritableExporter.writeIgnoringFailure(sampleExport())
  }

  // MARK: - Default location

  /// No iCloud entitlement, so the snapshot goes to Documents, which
  /// `UIFileSharingEnabled` exposes to the Files app.
  func testDefaultExportDirectoryLivesUnderDocuments() {
    let defaultDirectoryURL = PlaylistFolderTreeExporter.defaultExportDirectoryURL()
    XCTAssertEqual(
      defaultDirectoryURL.lastPathComponent,
      PlaylistFolderTreeExporter.exportDirectoryName
    )
    XCTAssertTrue(defaultDirectoryURL.deletingLastPathComponent().path.contains("Documents"))
  }
}
