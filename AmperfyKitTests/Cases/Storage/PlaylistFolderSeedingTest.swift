//
//  PlaylistFolderSeedingTest.swift
//  AmperfyKitTests
//
//  Created for AMP-24 — seeding an empty server from a stranded local tree.
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

// MARK: - StatefulServerStub

/// A folders-v2 server in miniature: starts EMPTY (the AMP-24 state), records
/// every create/upsert, and answers the organization fetch with exactly what
/// has landed — so reconciliation after a seed sees a truthful envelope.
private final class StatefulServerStub: @unchecked Sendable {
  private let lock = NSLock()
  private var folders = [NavidromeOrganizationFolder]()
  private var placements = [String: NavidromeOrganizationPlacement]()
  /// Folder names whose create must fail (partial-seed scenarios).
  var failingFolderNames = Set<String>()
  private(set) var createRequests = [(name: String, parentId: String?, sortOrder: Int?)]()

  struct CreateFailure: Error {}

  func organization() -> NavidromeFolderOrganizationResponse {
    lock.lock()
    defer { lock.unlock() }
    return NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: folders,
      placements: Array(placements.values)
    )
  }

  func create(name: String, parentId: String?, sortOrder: Int?) throws
    -> NavidromeOrganizationFolder {
    lock.lock()
    defer { lock.unlock() }
    createRequests.append((name, parentId, sortOrder))
    guard !failingFolderNames.contains(name) else { throw CreateFailure() }
    let created = NavidromeOrganizationFolder(
      id: PlaylistFolderNanoidFixture.make(),
      name: name,
      parentId: parentId ?? "",
      sortOrder: sortOrder
    )
    folders.append(created)
    return created
  }

  func upsertPlacement(folderId: String, playlistId: String, sortOrder: Int?) {
    lock.lock()
    defer { lock.unlock() }
    let normalizedFolderId = folderId == PlaylistFolderRootId.literal ? "" : folderId
    placements["\(playlistId)|\(normalizedFolderId)"] = NavidromeOrganizationPlacement(
      playlistId: playlistId, folderId: normalizedFolderId, sortOrder: sortOrder
    )
  }

  var serverFolderNames: [String] {
    lock.lock()
    defer { lock.unlock() }
    return folders.map(\.name).sorted()
  }

  func serverFolder(named name: String) -> NavidromeOrganizationFolder? {
    lock.lock()
    defer { lock.unlock() }
    return folders.first { $0.name == name }
  }

  var placementCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return placements.count
  }
}

// MARK: - PlaylistFolderSeedingTest

/// AMP-24: a folder tree built in the folders-v1 era (locally minted UUID ids)
/// was invisible to the pending-create replay, protected from the empty-server
/// wipe guard, and therefore stranded on one device forever — while prod held
/// zero rows. These tests pin the recovery: stranded ids are demoted to
/// pending creations and the whole tree (folders, filed placements, explicit
/// root ordering) lands on an empty server, converging in one sync pass, with
/// partial failures left pending and retried rather than lost.
@MainActor
class PlaylistFolderSeedingTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!
  private var server: StatefulServerStub!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PlaylistFolderStore(defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!)
    server = StatefulServerStub()
    configureStoreAgainstServer()
  }

  override func tearDown() {}

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  private func configureStoreAgainstServer() {
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      organizationFetcher: { [server] in server!.organization() },
      folderCreateRequester: { [server] name, parentId, sortOrder in
        try server!.create(name: name, parentId: parentId, sortOrder: sortOrder)
      },
      placementUpsertRequester: { [server] folderId, playlistId, sortOrder in
        server!.upsertPlacement(
          folderId: folderId, playlistId: playlistId, sortOrder: sortOrder
        )
      }
    )
  }

  /// A folder row as the folders-v1 client left it: locally minted UUID id.
  @discardableResult
  private func seedStrandedFolder(
    name: String, parentId: String? = nil, sortOrder: Int? = nil
  )
    -> PlaylistFolderMO {
    let folderMO = PlaylistFolderMO(context: testContext)
    folderMO.id = UUID().uuidString
    folderMO.name = name
    folderMO.parentId = parentId
    folderMO.sortOrderValue = sortOrder
    folderMO.account = account.managedObject
    try? testContext.save()
    return folderMO
  }

  @discardableResult
  private func seedPlacement(
    playlistId: String, playlistName: String, folderId: String, sortOrder: Int? = nil
  )
    -> PlaylistFolderPlacementMO {
    let playlist = library.createPlaylist(account: account)
    playlist.id = playlistId
    playlist.name = playlistName
    let placementMO = PlaylistFolderPlacementMO(context: testContext)
    placementMO.folderId = folderId
    placementMO.playlist = playlist.managedObject
    placementMO.sortOrder = sortOrder.map { NSNumber(value: $0) }
    placementMO.account = account.managedObject
    try? testContext.save()
    return placementMO
  }

  private func localFolders() -> [PlaylistFolderMO] {
    (try? testContext.fetch(PlaylistFolderMO.fetchRequest())) ?? []
  }

  // MARK: - The recovery itself

  func testStrandedTreeSeedsAnEmptyServerAndConvergesInOnePass() async throws {
    let parentMO = seedStrandedFolder(name: "Parent", sortOrder: 10)
    let originalParentId = parentMO.id
    seedStrandedFolder(name: "Child", parentId: parentMO.id, sortOrder: 20)
    seedPlacement(
      playlistId: "pl-filed", playlistName: "Filed", folderId: parentMO.id, sortOrder: 5
    )
    seedPlacement(
      playlistId: "pl-root", playlistName: "Root Ordered",
      folderId: PlaylistFolderRootId.canonical, sortOrder: 30
    )

    try await store.syncFromServer()

    // Server now holds the whole tree...
    XCTAssertEqual(server.serverFolderNames, ["Child", "Parent"])
    let serverParent = try XCTUnwrap(server.serverFolder(named: "Parent"))
    let serverChild = try XCTUnwrap(server.serverFolder(named: "Child"))
    XCTAssertEqual(
      serverChild.parentId, serverParent.id,
      "The child must be created under its parent's SERVER id"
    )
    XCTAssertEqual(server.placementCount, 2, "Filed + explicit root placement both pushed")

    // ...and the local tree has converged onto the server's ids, unharmed.
    let foldersById = Dictionary(
      localFolders().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )
    XCTAssertEqual(Set(foldersById.keys), Set([serverParent.id, serverChild.id]))
    XCTAssertEqual(store.allFiledPlaylistIds, ["pl-filed"])
    // A caller still holding the ORIGINAL stranded id resolves through the
    // demotion chain to the live server id.
    XCTAssertEqual(store.resolveFolderId(originalParentId), serverParent.id)
  }

  func testPartialSeedLeavesStragglersPendingAndCompletesNextSync() async throws {
    seedStrandedFolder(name: "Lands", sortOrder: 10)
    let strandedMO = seedStrandedFolder(name: "Fails", sortOrder: 20)
    seedPlacement(
      playlistId: "pl-in-failing", playlistName: "In Failing", folderId: strandedMO.id
    )
    server.failingFolderNames = ["Fails"]

    try await store.syncFromServer()

    XCTAssertEqual(server.serverFolderNames, ["Lands"])
    // The failed folder is now PENDING — not deleted, placement intact.
    let failingFolderMO = try XCTUnwrap(localFolders().first { $0.name == "Fails" })
    XCTAssertTrue(
      PlaylistFolder.isTemporaryId(failingFolderMO.id),
      "A create that did not land stays pending, immune to reconcile deletes"
    )
    XCTAssertEqual(
      store.folder(byId: failingFolderMO.id)?.playlistIds, ["pl-in-failing"],
      "The filed playlist survives with its pending folder"
    )

    // Next sync: the server-side block clears; the straggler lands.
    server.failingFolderNames = []
    try await store.syncFromServer()
    XCTAssertEqual(server.serverFolderNames, ["Fails", "Lands"])
    XCTAssertTrue(localFolders().allSatisfy { !PlaylistFolder.isTemporaryId($0.id) })
    XCTAssertEqual(server.placementCount, 1)
  }

  // MARK: - The non-empty-server hazard (the near-miss)

  /// The sharper edge of AMP-24: with even ONE folder on the server (say,
  /// created on another device), the sync takes the reconcile path — and a
  /// stranded UUID-id folder used to be indistinguishable from
  /// "deleted on the server", so reconciliation wiped it. UUID-shaped ids can
  /// never be server-issued, so they are demoted to pending BEFORE the probe
  /// and survive whatever the server tree holds.
  func testStrandedTreeSurvivesReconcileAgainstNonEmptyServer() async throws {
    _ = try? server.create(name: "Made Elsewhere", parentId: nil, sortOrder: nil)
    let strandedMO = seedStrandedFolder(name: "Phone Tree", sortOrder: 10)
    seedPlacement(
      playlistId: "pl-phone", playlistName: "Phone Playlist", folderId: strandedMO.id
    )

    try await store.syncFromServer()

    // Nothing was wiped: the stranded folder was demoted, pushed, and both
    // trees merged on the server.
    XCTAssertEqual(server.serverFolderNames, ["Made Elsewhere", "Phone Tree"])
    let phoneFolder = try XCTUnwrap(server.serverFolder(named: "Phone Tree"))
    XCTAssertEqual(
      store.folder(byId: phoneFolder.id)?.playlistIds, ["pl-phone"],
      "The phone's filed playlist survives the merge"
    )
  }

  // MARK: - Id plausibility

  func testServerIdPlausibility() {
    XCTAssertTrue(PlaylistFolder.isPlausibleServerId(PlaylistFolderNanoidFixture.make()))
    XCTAssertFalse(PlaylistFolder.isPlausibleServerId(UUID().uuidString))
    XCTAssertFalse(PlaylistFolder.isPlausibleServerId(PlaylistFolder.makeTemporaryId()))
    XCTAssertFalse(PlaylistFolder.isPlausibleServerId(""))
    XCTAssertFalse(PlaylistFolder.isPlausibleServerId("short"))
  }
}
