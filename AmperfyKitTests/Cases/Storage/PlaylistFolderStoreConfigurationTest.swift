//
//  PlaylistFolderStoreConfigurationTest.swift
//  AmperfyKitTests
//
//  Created for the fresh-install missing-folders regression (2026-09-26).
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

// MARK: - SilentTreeExporter

/// Swallows exports so the tests do not touch the file system.
private final class SilentTreeExporter: PlaylistFolderTreeExporter, @unchecked Sendable {
  override func writeIgnoringFailure(_ export: PlaylistFolderTreeExport) {}
}

// MARK: - PlaylistFolderStoreConfigurationTest

/// Regression net for the fresh-install missing-folders bug (found on the Mac,
/// 2026-09-26, but not Mac-specific).
///
/// `PlaylistFolderStore` is a singleton whose Core Data context and server API
/// are injected by `configure(...)`. That wiring lived only in
/// `didFinishLaunching` behind a `guard isLibrarySynced` — so a fresh
/// install's FIRST session (login → initial sync → main window, no relaunch)
/// ran entirely against an UNCONFIGURED store: it silently fell back to the
/// legacy UserDefaults mode, rendered no folders, treated every filed playlist
/// as unfiled (root), and `syncFromServer()` no-oped. These tests pin the
/// behavioral contract that made that failure invisible, so any future wiring
/// gap fails loudly here instead of shipping.
@MainActor
class PlaylistFolderStoreConfigurationTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var exporter: SilentTreeExporter!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    exporter = SilentTreeExporter(
      exportDirectoryURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaylistFolderStoreConfigurationTest-\(UUID().uuidString)")
    )
  }

  override func tearDown() {}

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  private func makeStore() -> PlaylistFolderStore {
    PlaylistFolderStore(
      defaults: UserDefaults(suiteName: "PFSConfigTest-\(UUID().uuidString)")!,
      treeExporter: exporter
    )
  }

  /// The fresh-install first session in miniature: folder data exists in the
  /// store's backing context (a synced device wrote it), but a store that was
  /// never `configure(...)`d renders nothing and files nothing — the exact
  /// "no folders, everything at the root" symptom. Configuring the same store
  /// over the same context is what makes the folders appear.
  func testFoldersInvisibleUntilStoreIsConfigured() {
    // A configured store writes a folder with a filed playlist — the state a
    // synced install has. The playlist must exist as a real row; placements
    // attach to PlaylistMO rows, not bare ids.
    let account = library.getAccount(info: TestAccountInfo.create1())
    let filedPlaylist = library.createPlaylist(account: account)
    filedPlaylist.id = "pl-filed"
    filedPlaylist.name = "Filed Playlist"
    library.saveContext()

    let configuredStore = makeStore()
    configuredStore.configureForTesting(context: testContext, account: nil)
    let folder = configuredStore.createFolder(name: "Rock", parent: nil)
    configuredStore.addPlaylists(["pl-filed"], to: folder.id)

    // A second store over the SAME data, never configured — what the whole
    // first session used. It must be treated as empty, which is the bug shape.
    let unconfiguredStore = makeStore()
    XCTAssertFalse(unconfiguredStore.isConfigured)
    XCTAssertTrue(
      unconfiguredStore.folders.isEmpty,
      "Unconfigured store falls back to legacy defaults and shows no folders"
    )
    XCTAssertTrue(
      unconfiguredStore.allFiledPlaylistIds.isEmpty,
      "Unconfigured store files nothing, so every playlist renders at the root"
    )

    // Wiring the store is the entire fix: same data, folders now visible.
    unconfiguredStore.configureForTesting(context: testContext, account: nil)
    XCTAssertEqual(unconfiguredStore.folders.map(\.name), ["Rock"])
    XCTAssertEqual(unconfiguredStore.allFiledPlaylistIds, ["pl-filed"])
  }

  /// `syncFromServer()` on an unconfigured store must stay a silent no-op —
  /// this is what made the bug invisible (no error surfaced anywhere), and it
  /// is also what makes calling sync paths before wiring safe. If this ever
  /// starts throwing, every fresh-login ordering assumption needs revisiting.
  func testUnconfiguredSyncFromServerIsSilentNoOp() async throws {
    let unconfiguredStore = makeStore()
    try await unconfiguredStore.syncFromServer()
    XCTAssertTrue(unconfiguredStore.folders.isEmpty)
    XCTAssertFalse(unconfiguredStore.isConfigured)
  }

  /// Configure is called from several account-lifecycle paths (launch, first
  /// login, account switch, post-logout re-login), so calling it repeatedly
  /// over the same context must be stable.
  func testConfigureIsIdempotent() {
    let store = makeStore()
    store.configureForTesting(context: testContext, account: nil)
    _ = store.createFolder(name: "Jazz", parent: nil)
    store.configureForTesting(context: testContext, account: nil)
    XCTAssertEqual(store.folders.map(\.name), ["Jazz"])
  }
}
