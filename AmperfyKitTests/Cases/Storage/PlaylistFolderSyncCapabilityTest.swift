//
//  PlaylistFolderSyncCapabilityTest.swift
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

/// Regression tests for the playlist-folder sync capability probe.
///
/// This fork shipped against a Navidrome folder API that was never deployed, so
/// every folder request 404'd behind a `try?`. On 2026-08-02 a resync against a
/// corrupted server took the success branch and delete-if-absent reconciliation
/// wiped the owner's entire folder tree. These tests pin the rule that made that
/// impossible: no destructive reconciliation without positive proof — an HTTP
/// 200 whose body is a `folderApiVersion >= 2` organization envelope.
@MainActor
class PlaylistFolderSyncCapabilityTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PlaylistFolderStore(defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Helpers

  /// Seed a folder straight into Core Data, standing in for folders the device
  /// already holds before a sync runs.
  @discardableResult
  private func seedLocalFolder(
    serverId: String,
    name: String,
    parentId: String? = nil
  )
    -> PlaylistFolderMO {
    let folderMO = PlaylistFolderMO(context: testContext)
    folderMO.id = serverId
    folderMO.name = name
    folderMO.parentId = parentId
    folderMO.account = account.managedObject
    try? testContext.save()
    return folderMO
  }

  private var storedFolderNames: [String] {
    let fetchRequest = PlaylistFolderMO.fetchRequest()
    let folderMOs = (try? testContext.fetch(fetchRequest)) ?? []
    return folderMOs.map { $0.name }.sorted()
  }

  private func configureStore(
    organizationFetcher: @escaping PlaylistFolderOrganizationFetcher
  ) {
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      organizationFetcher: organizationFetcher
    )
  }

  /// Decode a raw body exactly as the API client would, so "the server sent
  /// this JSON" is what the test asserts on — not a hand-built error.
  private nonisolated static func decodeOrganization(rawBody: String) throws
    -> NavidromeFolderOrganizationResponse {
    try JSONDecoder().decode(
      NavidromeFolderOrganizationResponse.self,
      from: Data(rawBody.utf8)
    )
  }

  // MARK: - 1. Stock Navidrome (404) must never delete

  func testEndpointNotFoundLeavesLocalFoldersUntouched() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-jazz", name: "Jazz")

    configureStore { throw NavidromeApiError.notFound }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Jazz", "Rock"])
  }

  func testEndpointNotFoundIsClassifiedAsUnsupported() {
    let reason = PlaylistFolderSyncCapability.unsupportedReason(
      for: NavidromeApiError.notFound
    )
    XCTAssertEqual(reason, .endpointNotFound)
  }

  // MARK: - 2. HTTP 200 with a non-envelope body must never delete

  /// The never-deployed v1 fork answered with a bare JSON array. A 200 is not
  /// proof of anything — only the envelope is.
  func testLegacyArrayResponseLeavesLocalFoldersUntouched() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-jazz", name: "Jazz")

    let legacyArrayBody = """
    [{"id":"server-only","name":"Server Only","parent_id":null}]
    """
    configureStore { try Self.decodeOrganization(rawBody: legacyArrayBody) }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Jazz", "Rock"])
  }

  /// A JSON object that simply lacks `folderApiVersion` is equally unproven.
  func testObjectWithoutFolderApiVersionLeavesLocalFoldersUntouched() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")

    let bodyWithoutVersion = """
    {"folders":[],"placements":[]}
    """
    configureStore { try Self.decodeOrganization(rawBody: bodyWithoutVersion) }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Rock"])
  }

  /// A well-formed envelope that predates the agreed contract is also refused.
  func testFolderApiVersionBelowMinimumLeavesLocalFoldersUntouched() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 1,
        folders: [],
        placements: []
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Rock"])
  }

  // MARK: - 3. A genuine v2 envelope lets reconciliation proceed

  func testV2EnvelopeReconcilesFoldersIncludingDeletion() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-stale", name: "Stale")

    let envelopeBody = """
    {
      "folderApiVersion": 2,
      "folders": [
        {"id":"folder-rock","name":"Rock Renamed","parentId":"","sortOrder":0},
        {"id":"folder-new","name":"New From Server","parentId":"","sortOrder":1}
      ],
      "placements": [
        {"playlistId":"pl-1","folderId":"folder-rock","sortOrder":0}
      ]
    }
    """
    configureStore { try Self.decodeOrganization(rawBody: envelopeBody) }
    try await store.syncFromServer()

    // "Stale" was absent from a capability-confirmed server, so it is deleted;
    // "Rock" is renamed in place and "New From Server" is created.
    XCTAssertEqual(storedFolderNames, ["New From Server", "Rock Renamed"])
  }

  /// A root folder arrives with `parentId: ""`; local storage spells root as
  /// `nil`, so the folder must land at the root of the tree.
  func testV2EnvelopeNormalizesEmptyParentIdToRoot() async throws {
    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-root", name: "Root", parentId: ""),
        ],
        placements: []
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(store.folders.count, 1)
    XCTAssertEqual(store.folders.first?.name, "Root")
  }

  // MARK: - 4. Empty-wipe belt — the exact shape of the Aug-2 data loss

  func testEmptyServerOrganizationDoesNotWipeNonEmptyLocalFolders() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-jazz", name: "Jazz")
    seedLocalFolder(serverId: "folder-metal", name: "Metal", parentId: "folder-rock")

    let emptyOrganizationBody = """
    {"folderApiVersion": 2, "folders": [], "placements": []}
    """
    configureStore { try Self.decodeOrganization(rawBody: emptyOrganizationBody) }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Jazz", "Metal", "Rock"])
  }

  /// The belt must not block a legitimately empty first sync — no local folders
  /// means there is nothing to lose.
  func testEmptyServerOrganizationWithEmptyLocalStorageIsAllowed() async throws {
    configureStore {
      NavidromeFolderOrganizationResponse(folderApiVersion: 2)
    }
    try await store.syncFromServer()

    XCTAssertTrue(storedFolderNames.isEmpty)
  }

  // MARK: - 5. Decision layer, exercised directly

  func testDecisionReconcilesOnConfirmedNonEmptyOrganization() {
    let organization = NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: [NavidromeOrganizationFolder(id: "f1", name: "Rock", parentId: nil)],
      placements: []
    )
    let decision = PlaylistFolderSyncCapability.evaluate(
      probeOutcome: .success(organization),
      localFolderCount: 5
    )
    guard case .reconcile = decision else {
      return XCTFail("Expected reconcile, got \(decision)")
    }
  }

  func testDecisionSkipsEmptyOrganizationAgainstNonEmptyLocalStorage() {
    let decision = PlaylistFolderSyncCapability.evaluate(
      probeOutcome: .success(NavidromeFolderOrganizationResponse(folderApiVersion: 2)),
      localFolderCount: 7
    )
    guard case let .skipEmptyServerOrganizationWouldWipeLocalFolders(localFolderCount)
      = decision else {
      return XCTFail("Expected empty-organization skip, got \(decision)")
    }
    XCTAssertEqual(localFolderCount, 7)
  }

  func testDecisionSkipsOnAnyProbeFailure() {
    let failures: [Error] = [
      NavidromeApiError.notFound,
      NavidromeApiError.unauthorized,
      NavidromeApiError.serverError(500),
      NavidromeApiError.networkError(URLError(.timedOut)),
    ]
    for probeError in failures {
      let decision = PlaylistFolderSyncCapability.evaluate(
        probeOutcome: .failure(probeError),
        localFolderCount: 3
      )
      guard case .skipServerLacksFolderApi = decision else {
        return XCTFail("Expected skip for \(probeError), got \(decision)")
      }
    }
  }

  func testDecodingFailureIsClassifiedAsNonEnvelopeResponse() {
    let legacyArrayBody = "[{\"id\":\"a\",\"name\":\"A\"}]"
    do {
      _ = try Self.decodeOrganization(rawBody: legacyArrayBody)
      XCTFail("Legacy array body must not decode as a v2 envelope")
    } catch {
      XCTAssertEqual(
        PlaylistFolderSyncCapability.unsupportedReason(for: error),
        .responseNotAnOrganizationEnvelope
      )
    }
  }

  // MARK: - 6. Envelope decoding

  func testV2EnvelopeDecodesFoldersAndPlacements() throws {
    let envelopeBody = """
    {
      "folderApiVersion": 2,
      "folders": [{"id":"f1","name":"Rock","parentId":"","sortOrder":3}],
      "placements": [{"playlistId":"pl-1","folderId":"","sortOrder":2}]
    }
    """
    let organization = try Self.decodeOrganization(rawBody: envelopeBody)

    XCTAssertEqual(organization.folderApiVersion, 2)
    XCTAssertEqual(organization.folders.count, 1)
    XCTAssertEqual(organization.folders.first?.name, "Rock")
    XCTAssertNil(organization.folders.first?.normalizedParentId)
    XCTAssertEqual(organization.folders.first?.sortOrder, 3)
    XCTAssertEqual(organization.placements.count, 1)
    XCTAssertEqual(organization.placements.first?.playlistId, "pl-1")
    XCTAssertFalse(organization.isEmptyOrganization)
  }

  func testEnvelopeWithMissingArraysDecodesAsEmptyOrganization() throws {
    let organization = try Self.decodeOrganization(
      rawBody: "{\"folderApiVersion\": 2}"
    )
    XCTAssertTrue(organization.isEmptyOrganization)
  }

  /// Placements alone still count as a populated organization, so the empty
  /// belt does not fire while the server is mid-migration to placement-only
  /// storage.
  func testOrganizationWithPlacementsOnlyIsNotEmpty() {
    let organization = NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: [],
      placements: [NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "f1")]
    )
    XCTAssertFalse(organization.isEmptyOrganization)
  }
}
