//
//  PlaylistFolderCreationTest.swift
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

// MARK: - SilentTreeExporter

/// Swallows exports so the tests do not touch the file system.
private final class SilentTreeExporter: PlaylistFolderTreeExporter, @unchecked Sendable {
  override func writeIgnoringFailure(_ export: PlaylistFolderTreeExport) {}
}

// MARK: - CreateRequestLog

/// Records what the stubbed POST was asked for.
///
/// A lock rather than the test case itself, because the requester closure is
/// `@Sendable` and runs off the main actor — the same reason the sync tests keep
/// their own `ServerCallLog`.
private final class CreateRequestLog: @unchecked Sendable {
  struct Request: Equatable {
    let name: String
    let parentId: String?
    let sortOrder: Int?
  }

  private let lock = NSLock()
  private var requests = [Request]()

  func record(name: String, parentId: String?, sortOrder: Int?) {
    lock.lock()
    defer { lock.unlock() }
    requests.append(Request(name: name, parentId: parentId, sortOrder: sortOrder))
  }

  var recordedRequests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

// MARK: - PlaylistFolderCreationTest

/// End-to-end coverage of creating a folder and adopting the id the server gives
/// it back.
///
/// A folder is created optimistically so the UI responds at once, under a
/// temporary local id, and swaps to the server's id when the POST returns —
/// carrying across any placements or child folders made against it in between.
/// A rebuild session is dozens of these in a row, each racing whatever the user
/// does next, so the flow is exercised here through the store's real create path
/// with the network call replaced at the `PlaylistFolderCreateRequester` seam.
@MainActor
class PlaylistFolderCreationTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!
  private var exporter: SilentTreeExporter!

  private var createRequestLog: CreateRequestLog!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    exporter = SilentTreeExporter(
      exportDirectoryURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaylistFolderCreationTest-\(UUID().uuidString)")
    )
    store = PlaylistFolderStore(
      defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!,
      treeExporter: exporter
    )
    createRequestLog = CreateRequestLog()
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Seam wiring

  /// Configure the store so the create POST succeeds, answering with `serverId`.
  private func configureStoreWithSuccessfulCreate(
    serverId: String,
    parentId: String? = nil,
    sortOrder: Int? = nil
  ) {
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      folderCreateRequester: { [createRequestLog] name, requestedParentId, requestedSortOrder in
        createRequestLog!.record(
          name: name, parentId: requestedParentId, sortOrder: requestedSortOrder
        )
        return NavidromeOrganizationFolder(
          id: serverId,
          name: name,
          parentId: parentId ?? requestedParentId ?? "",
          sortOrder: sortOrder ?? requestedSortOrder
        )
      }
    )
  }

  private struct CreateFailure: Error {}

  private func configureStoreWithFailingCreate() {
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      folderCreateRequester: { [createRequestLog] name, parentId, sortOrder in
        createRequestLog!.record(name: name, parentId: parentId, sortOrder: sortOrder)
        throw CreateFailure()
      }
    )
  }

  /// Wait until the folder is reachable under `serverId`.
  ///
  /// Adoption happens on a detached task that hops to the main actor, so the
  /// await here is what lets it run. Polling the condition rather than counting
  /// exports keeps the wait honest: every other mutation exports too, so a
  /// write-counting expectation would be fulfilled by unrelated work.
  private func waitForAdoption(
    of serverId: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if store.folder(byId: serverId) != nil { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("the server id \(serverId) was never adopted", file: file, line: line)
  }

  /// Let the create task run to completion when no adoption is expected.
  private func waitForCreateAttempt() async {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, createRequestLog.recordedRequests.isEmpty {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    // The requester has been called; give its failure path a turn to finish.
    try? await Task.sleep(nanoseconds: 50_000_000)
  }

  @discardableResult
  private func seedPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    try? testContext.save()
    return playlist
  }

  // MARK: - Successful creation

  func testTheServerIdIsAdoptedWhenTheCreatePostReturns() async {
    let serverId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: serverId)

    let createdFolder = store.createFolder(name: "Rock", parent: nil)
    let temporaryId = createdFolder.id
    await waitForAdoption(of: serverId)

    XCTAssertNil(store.folder(byId: temporaryId), "the temporary id must stop resolving")
    XCTAssertEqual(store.folder(byId: serverId)?.name, "Rock")
    XCTAssertEqual(store.folders.map(\.id), [serverId])
  }

  func testTheCreateRequestCarriesTheNameAndTheAppendedSortOrder() async {
    let serverId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: serverId)

    store.createFolder(name: "Rock", parent: nil)
    await waitForAdoption(of: serverId)

    XCTAssertEqual(createRequestLog.recordedRequests.count, 1)
    XCTAssertEqual(createRequestLog.recordedRequests.first?.name, "Rock")
    XCTAssertNil(createRequestLog.recordedRequests.first?.parentId)
    // First folder at the root, so the first gap.
    XCTAssertEqual(
      createRequestLog.recordedRequests.first?.sortOrder,
      PlaylistFolderOrdering.sortOrderGap
    )
  }

  func testCreatingInsideAFolderSendsThatFoldersServerId() async {
    let parentServerId = PlaylistFolderNanoidFixture.make()
    let parentFolderMO = PlaylistFolderMO(context: testContext)
    parentFolderMO.id = parentServerId
    parentFolderMO.name = "Parent"
    parentFolderMO.account = account.managedObject
    try? testContext.save()

    let childServerId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: childServerId, parentId: parentServerId)

    store.createFolder(name: "Child", parent: parentServerId)
    await waitForAdoption(of: childServerId)

    XCTAssertEqual(createRequestLog.recordedRequests.first?.parentId, parentServerId)
    XCTAssertEqual(store.folder(byId: parentServerId)?.subfolders.map(\.id), [childServerId])
  }

  func testAdoptionTakesTheServersParentAndSortOrder() async {
    let serverId = PlaylistFolderNanoidFixture.make()
    // The server is free to answer with a different sortOrder than was asked for.
    configureStoreWithSuccessfulCreate(serverId: serverId, parentId: "", sortOrder: 940)

    store.createFolder(name: "Rock", parent: nil)
    await waitForAdoption(of: serverId)

    XCTAssertEqual(store.folder(byId: serverId)?.sortOrder, 940)
  }

  func testPlacementsAndChildFoldersMadeBeforeAdoptionFollowTheServerId() async {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let serverId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: serverId)

    let createdFolder = store.createFolder(name: "Rock", parent: nil)
    // The user carries on organizing while the POST is still in flight — the
    // whole reason the folder is created optimistically.
    store.addPlaylists(["pl-1"], to: createdFolder.id)
    await waitForAdoption(of: serverId)

    let adoptedFolder = try? XCTUnwrap(store.folder(byId: serverId))
    XCTAssertEqual(adoptedFolder?.playlistIds, ["pl-1"])
    XCTAssertTrue(store.allFiledPlaylistIds.contains("pl-1"))
  }

  func testTheExportNamesTheServerIdOnceAdopted() async {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let serverId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: serverId)

    let createdFolder = store.createFolder(name: "Rock", parent: nil)
    store.addPlaylists(["pl-1"], to: createdFolder.id)
    await waitForAdoption(of: serverId)

    // The JSON snapshot is the fallback if everything else is lost, so it has to
    // name the id the server knows — a temporary id would restore to nothing.
    let export = store.buildExport(from: testContext)
    XCTAssertEqual(export.folders.map(\.id), [serverId])
    XCTAssertEqual(export.placements.map(\.folderId), [serverId])
  }

  func testAdoptionDoesNotNotifyObservers() async {
    let serverId = PlaylistFolderNanoidFixture.make()
    configureStoreWithSuccessfulCreate(serverId: serverId)

    var notificationCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: PlaylistFolderStore.didChangeNotification,
      object: store,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.createFolder(name: "Rock", parent: nil)
    await waitForAdoption(of: serverId)

    // Pinned, not endorsed: only the synchronous create notifies. The adoption
    // changes the folder's id without telling anyone, so a screen scoped to the
    // temporary id keeps a dead id until something else triggers a reload.
    XCTAssertEqual(notificationCount, 1)
  }

  // MARK: - Offline

  func testWithNoCreateRequesterTheFolderStaysLocalUnderItsTemporaryId() {
    store.configureForTesting(context: testContext, account: account.managedObject)

    let createdFolder = store.createFolder(name: "Rock", parent: nil)

    XCTAssertEqual(store.folder(byId: createdFolder.id)?.name, "Rock")
    XCTAssertTrue(createRequestLog.recordedRequests.isEmpty)
  }

  // MARK: - Failed creation

  func testAFailedCreateLeavesTheFolderUsableLocally() async {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    configureStoreWithFailingCreate()

    let createdFolder = store.createFolder(name: "Rock", parent: nil)
    await waitForCreateAttempt()
    store.addPlaylists(["pl-1"], to: createdFolder.id)

    // The folder survives the failure and can still be organized into: the
    // optimistic entry is never rolled back.
    XCTAssertEqual(store.folder(byId: createdFolder.id)?.name, "Rock")
    XCTAssertEqual(store.folder(byId: createdFolder.id)?.playlistIds, ["pl-1"])
    XCTAssertEqual(createRequestLog.recordedRequests.count, 1)
  }

  func testAFailedCreateIsNeverRetried() async {
    configureStoreWithFailingCreate()

    store.createFolder(name: "Rock", parent: nil)
    await waitForCreateAttempt()

    // Pinned, not endorsed: there is no retry and no pending-create queue, so the
    // folder keeps a temporary id the server has never heard of, indefinitely.
    XCTAssertEqual(createRequestLog.recordedRequests.count, 1)
  }

  /// **This test pins a defect, not a desired behaviour.**
  ///
  /// A folder whose create POST failed keeps its temporary id. Reconciliation
  /// deletes every local folder absent from the server envelope, and the server
  /// has never heard of this one — so the next successful sync deletes the
  /// folder and cascades away every placement filed into it. The playlists
  /// themselves survive (placements are edges, not membership), but the
  /// organizing work is destroyed silently.
  ///
  /// The `skipEmptyServerOrganizationWouldWipeLocalFolders` guard does not help:
  /// it only refuses a *wholly* empty envelope, and here the envelope has real
  /// folders in it.
  func testAFailedCreateFolderIsSilentlyDeletedByTheNextSuccessfulSync() async throws {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    configureStoreWithFailingCreate()

    let createdFolder = store.createFolder(name: "Rock", parent: nil)
    await waitForCreateAttempt()
    store.addPlaylists(["pl-1"], to: createdFolder.id)
    XCTAssertEqual(store.folder(byId: createdFolder.id)?.playlistIds, ["pl-1"])

    // A sync where the server reports a real, non-empty organization that simply
    // does not include the folder whose creation failed.
    let existingServerFolderId = PlaylistFolderNanoidFixture.make()
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      organizationFetcher: {
        NavidromeFolderOrganizationResponse(
          folderApiVersion: 2,
          folders: [
            NavidromeOrganizationFolder(
              id: existingServerFolderId, name: "Existing", parentId: ""
            ),
          ],
          placements: []
        )
      }
    )
    try await store.syncFromServer()

    XCTAssertNil(store.folder(byId: createdFolder.id), "the folder is gone")
    XCTAssertFalse(
      store.allFiledPlaylistIds.contains("pl-1"),
      "and the placement filed into it went with it"
    )
    // The playlist itself is untouched — placements are edges, never membership.
    XCTAssertNotNil(library.getPlaylists(for: account).first { $0.id == "pl-1" })
    XCTAssertEqual(store.folders.map(\.id), [existingServerFolderId])
  }
}
