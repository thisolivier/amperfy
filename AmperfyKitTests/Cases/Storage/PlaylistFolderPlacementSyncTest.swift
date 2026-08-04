//
//  PlaylistFolderPlacementSyncTest.swift
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

// MARK: - PlaylistFolderPlacementSyncTest

/// Tests for placement-driven membership reconciliation.
///
/// Before this change memberships were refilled from a per-folder detail
/// request, so a folder whose detail fetch failed was quietly emptied. The
/// envelope carries folders and placements together, and these tests pin the two
/// rules that distinction depends on: a folder with no placements is *empty*,
/// not missing, and a placement naming an unknown playlist is *skipped*, not
/// fabricated.
@MainActor
class PlaylistFolderPlacementSyncTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!
  private var exportDirectoryURL: URL!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    exportDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PlaylistFolderPlacementSyncTest-\(PlaylistFolderNanoidFixture.make())"
      )
    store = PlaylistFolderStore(
      defaults: UserDefaults(suiteName: "\(PlaylistFolderNanoidFixture.make())")!,
      treeExporter: PlaylistFolderTreeExporter(exportDirectoryURL: exportDirectoryURL)
    )
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: exportDirectoryURL)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  // MARK: - Helpers

  @discardableResult
  private func seedLocalFolder(
    serverId: String,
    name: String,
    parentId: String? = nil,
    sortOrder: Int? = nil
  )
    -> PlaylistFolderMO {
    let folderMO = PlaylistFolderMO(context: testContext)
    folderMO.id = serverId
    folderMO.name = name
    folderMO.parentId = parentId
    folderMO.sortOrderValue = sortOrder
    folderMO.account = account.managedObject
    try? testContext.save()
    return folderMO
  }

  @discardableResult
  private func seedLocalPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    try? testContext.save()
    return playlist
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

  /// A folder delete notifies twice: once synchronously for the local part, and
  /// again once the post-delete refetch has reconciled. Waiting on the *second*
  /// is what makes an assertion about the converged state deterministic —
  /// waiting on the fetch itself only proves the request went out.
  private func expectationForDeleteConvergence() -> XCTestExpectation {
    let convergenceExpectation = expectation(
      forNotification: PlaylistFolderStore.didChangeNotification,
      object: nil,
      handler: nil
    )
    convergenceExpectation.expectedFulfillmentCount = 2
    return convergenceExpectation
  }

  private func storedPlacementSortOrders() -> [String: Int] {
    let fetchRequest = PlaylistFolderPlacementMO.fetchRequest()
    let placementMOs = (try? testContext.fetch(fetchRequest)) ?? []
    var sortOrders = [String: Int]()
    for placementMO in placementMOs {
      guard let playlistId = placementMO.playlist?.id,
            let sortOrder = placementMO.sortOrderValue else { continue }
      sortOrders["\(playlistId)@\(placementMO.folderId)"] = sortOrder
    }
    return sortOrders
  }

  private func storedPlacementEdges() -> [String] {
    let fetchRequest = PlaylistFolderPlacementMO.fetchRequest()
    let placementMOs = (try? testContext.fetch(fetchRequest)) ?? []
    return placementMOs
      .map { "\($0.playlist?.id ?? "?")@\($0.folderId)" }
      .sorted()
  }

  private var storedFolderNames: [String] {
    let folderMOs = (try? testContext.fetch(PlaylistFolderMO.fetchRequest())) ?? []
    return folderMOs.map { $0.name }.sorted()
  }

  // MARK: - 1. Placements drive membership

  func testPlacementsFromEnvelopeCreateLocalMemberships() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    seedLocalPlaylist(id: "pl-2", name: "Solos")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(
            playlistId: "pl-1", folderId: "folder-rock", sortOrder: 10
          ),
          NavidromeOrganizationPlacement(
            playlistId: "pl-2", folderId: "folder-rock", sortOrder: 20
          ),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedPlacementEdges(), ["pl-1@folder-rock", "pl-2@folder-rock"])
    XCTAssertEqual(store.folders.first?.playlistIds, ["pl-1", "pl-2"])
  }

  /// The contract allows a playlist in several folders at once — placements are
  /// edges, not a single membership.
  func testPlaylistCanBePlacedInSeveralFolders() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-favs", name: "Favourites")
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
          NavidromeOrganizationFolder(id: "folder-favs", name: "Favourites", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-rock"),
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-favs"),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedPlacementEdges(), ["pl-1@folder-favs", "pl-1@folder-rock"])
  }

  /// Placement ordering is what the folder tree exposes as playlist order.
  func testPlacementSortOrderDrivesPlaylistOrderWithinAFolder() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalPlaylist(id: "pl-a", name: "Alpha")
    seedLocalPlaylist(id: "pl-b", name: "Bravo")
    seedLocalPlaylist(id: "pl-c", name: "Charlie")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          // Deliberately reversed relative to name order.
          NavidromeOrganizationPlacement(
            playlistId: "pl-c", folderId: "folder-rock", sortOrder: 10
          ),
          NavidromeOrganizationPlacement(
            playlistId: "pl-a", folderId: "folder-rock", sortOrder: 30
          ),
          NavidromeOrganizationPlacement(
            playlistId: "pl-b", folderId: "folder-rock", sortOrder: 20
          ),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(store.folders.first?.playlistIds, ["pl-c", "pl-b", "pl-a"])
  }

  /// A placement with no sortOrder sorts after the ordered ones.
  func testPlacementWithoutSortOrderSortsLast() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalPlaylist(id: "pl-ordered", name: "Zulu")
    seedLocalPlaylist(id: "pl-unordered", name: "Alpha")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(
            playlistId: "pl-unordered", folderId: "folder-rock", sortOrder: nil
          ),
          NavidromeOrganizationPlacement(
            playlistId: "pl-ordered", folderId: "folder-rock", sortOrder: 10
          ),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(store.folders.first?.playlistIds, ["pl-ordered", "pl-unordered"])
  }

  // MARK: - 2. Never fabricate

  func testPlacementForUnknownPlaylistIsSkippedNotFabricated() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalPlaylist(id: "pl-known", name: "Known")

    let playlistCountBefore = library.getPlaylists(for: account).count

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-known", folderId: "folder-rock"),
          NavidromeOrganizationPlacement(
            playlistId: "pl-this-device-has-never-seen", folderId: "folder-rock"
          ),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedPlacementEdges(), ["pl-known@folder-rock"])
    XCTAssertEqual(
      library.getPlaylists(for: account).count, playlistCountBefore,
      "Folder sync must never create playlists"
    )
  }

  /// A placement into a folder the same envelope never declared cannot be
  /// honoured — there is nothing to file it into.
  func testPlacementIntoUndeclaredFolderIsSkipped() async throws {
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-ghost"),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertTrue(storedPlacementEdges().isEmpty)
  }

  // MARK: - 3. Empty folder is not a missing folder

  func testFolderWithNoPlacementsSurvivesAsAnEmptyFolder() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalFolder(serverId: "folder-empty", name: "Empty")
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
          NavidromeOrganizationFolder(id: "folder-empty", name: "Empty", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-rock"),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Empty", "Rock"])
    let emptyFolder = store.folders.first { $0.name == "Empty" }
    XCTAssertNotNil(emptyFolder)
    XCTAssertTrue(emptyFolder?.playlistIds.isEmpty ?? false)
  }

  /// A previously-filed playlist whose placement the server dropped becomes
  /// unfiled — but the playlist itself must survive untouched.
  func testDroppedPlacementUnfilesThePlaylistWithoutDeletingIt() async throws {
    seedLocalFolder(serverId: "folder-rock", name: "Rock")
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-rock"),
        ]
      )
    }
    try await store.syncFromServer()
    XCTAssertEqual(storedPlacementEdges(), ["pl-1@folder-rock"])

    // Second pass: the server still owns folders, but no longer files pl-1.
    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: []
      )
    }
    try await store.syncFromServer()

    XCTAssertTrue(storedPlacementEdges().isEmpty)
    XCTAssertEqual(storedFolderNames, ["Rock"])
    XCTAssertNotNil(
      library.getPlaylists(for: account).first { $0.id == "pl-1" },
      "Dropping a placement must never reach through to the playlist"
    )
  }

  /// Deleting a folder cascades to its placements but must not touch playlists —
  /// the Nullify/Cascade split the v52 model was designed around.
  func testDeletingAFolderServerSideKeepsItsPlaylists() async throws {
    seedLocalFolder(serverId: "folder-doomed", name: "Doomed")
    seedLocalFolder(serverId: "folder-keep", name: "Keep")
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-doomed", name: "Doomed", parentId: ""),
          NavidromeOrganizationFolder(id: "folder-keep", name: "Keep", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "folder-doomed"),
        ]
      )
    }
    try await store.syncFromServer()

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-keep", name: "Keep", parentId: ""),
        ],
        placements: []
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedFolderNames, ["Keep"])
    XCTAssertTrue(storedPlacementEdges().isEmpty)
    XCTAssertNotNil(library.getPlaylists(for: account).first { $0.id == "pl-1" })
  }

  // MARK: - 4. Root placements

  /// The server spells the root as an empty folderId, and also accepts "root".
  /// Both must normalize to the same local edge, and a root placement must not
  /// count the playlist as filed.
  func testRootPlacementsNormalizeAndDoNotCountAsFiled() async throws {
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    seedLocalPlaylist(id: "pl-2", name: "Solos")

    configureStore {
      NavidromeFolderOrganizationResponse(
        folderApiVersion: 2,
        folders: [
          NavidromeOrganizationFolder(id: "folder-rock", name: "Rock", parentId: ""),
        ],
        placements: [
          NavidromeOrganizationPlacement(
            playlistId: "pl-1", folderId: "", sortOrder: 10
          ),
          NavidromeOrganizationPlacement(
            playlistId: "pl-2", folderId: "root", sortOrder: 20
          ),
        ]
      )
    }
    try await store.syncFromServer()

    XCTAssertEqual(storedPlacementEdges(), ["pl-1@", "pl-2@"])
    XCTAssertTrue(
      store.allFiledPlaylistIds.isEmpty,
      "A root placement orders a playlist at the root, it does not file it away"
    )
    XCTAssertEqual(
      store.playlistSortOrders(inFolder: nil),
      ["pl-1": 10, "pl-2": 20]
    )
  }

  // MARK: - 5. Reconciler resolution, exercised directly

  func testResolverReportsSkippedUnknownPlaylists() {
    let organization = NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: [NavidromeOrganizationFolder(id: "f1", name: "Rock", parentId: "")],
      placements: [
        NavidromeOrganizationPlacement(playlistId: "known", folderId: "f1"),
        NavidromeOrganizationPlacement(playlistId: "unknown", folderId: "f1"),
      ]
    )
    let resolution = PlaylistFolderPlacementReconciler.resolve(
      organization: organization,
      knownPlaylistIds: ["known"]
    )
    XCTAssertEqual(resolution.resolvedPlacements.count, 1)
    XCTAssertEqual(resolution.skippedUnknownPlaylistIds, ["unknown"])
  }

  func testResolverDropsDuplicateEdges() {
    let organization = NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: [NavidromeOrganizationFolder(id: "f1", name: "Rock", parentId: "")],
      placements: [
        NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "f1", sortOrder: 10),
        NavidromeOrganizationPlacement(playlistId: "pl-1", folderId: "f1", sortOrder: 99),
      ]
    )
    let resolution = PlaylistFolderPlacementReconciler.resolve(
      organization: organization,
      knownPlaylistIds: ["pl-1"]
    )
    XCTAssertEqual(resolution.resolvedPlacements.count, 1)
    XCTAssertEqual(resolution.resolvedPlacements.first?.sortOrder, 10)
  }

  func testResolverKeepsFoldersWithoutPlacements() {
    let organization = NavidromeFolderOrganizationResponse(
      folderApiVersion: 2,
      folders: [NavidromeOrganizationFolder(id: "f1", name: "Empty", parentId: "")],
      placements: []
    )
    let resolution = PlaylistFolderPlacementReconciler.resolve(
      organization: organization,
      knownPlaylistIds: ["pl-1"]
    )
    XCTAssertTrue(resolution.resolvedPlacements.isEmpty)
    XCTAssertTrue(resolution.skippedUnknownPlaylistIds.isEmpty)
    XCTAssertTrue(resolution.skippedUnknownFolderIds.isEmpty)
  }

  // MARK: - 6. Local write paths

  func testAddingPlaylistsToAFolderAppendsWithGapNumbering() async throws {
    let folder = store.createFolderForTesting(
      context: testContext, account: account, name: "Rock"
    )
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    seedLocalPlaylist(id: "pl-2", name: "Solos")

    store.addPlaylists(["pl-1"], to: folder.id)
    store.addPlaylists(["pl-2"], to: folder.id)

    let sortOrders = store.playlistSortOrders(inFolder: folder.id)
    XCTAssertEqual(sortOrders["pl-1"], 10)
    XCTAssertEqual(sortOrders["pl-2"], 20)
  }

  func testMovingASiblingReordersItWithinItsParent() async throws {
    let folder = store.createFolderForTesting(
      context: testContext, account: account, name: "Rock"
    )
    seedLocalPlaylist(id: "pl-a", name: "Alpha")
    seedLocalPlaylist(id: "pl-b", name: "Bravo")
    seedLocalPlaylist(id: "pl-c", name: "Charlie")
    store.addPlaylists(["pl-a", "pl-b", "pl-c"], to: folder.id)

    XCTAssertEqual(store.folder(byId: folder.id)?.playlistIds, ["pl-a", "pl-b", "pl-c"])

    store.moveSibling(kind: .playlist, id: "pl-c", inFolder: folder.id, toIndex: 0)

    XCTAssertEqual(store.folder(byId: folder.id)?.playlistIds, ["pl-c", "pl-a", "pl-b"])
  }

  func testRemovingAPlaylistDropsOnlyItsPlacement() async throws {
    let folder = store.createFolderForTesting(
      context: testContext, account: account, name: "Rock"
    )
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    store.addPlaylists(["pl-1"], to: folder.id)
    XCTAssertEqual(storedPlacementEdges().count, 1)

    store.removePlaylists(["pl-1"], from: folder.id)

    XCTAssertTrue(storedPlacementEdges().isEmpty)
    XCTAssertNotNil(library.getPlaylists(for: account).first { $0.id == "pl-1" })
  }

  /// Re-parenting a folder under its own descendant is refused locally, the same
  /// way the server answers 400.
  func testMovingAFolderIntoItsOwnDescendantIsRefused() async throws {
    let parentFolder = store.createFolderForTesting(
      context: testContext, account: account, name: "Parent"
    )
    let childFolder = store.createFolderForTesting(
      context: testContext, account: account, name: "Child", parent: parentFolder.id
    )

    store.moveFolder(id: parentFolder.id, toParent: childFolder.id)

    XCTAssertEqual(store.folders.map(\.name), ["Parent"])
    XCTAssertEqual(store.folders.first?.subfolders.map(\.name), ["Child"])
  }

  // MARK: - 7. Folder delete defers promotion to the server

  /// The whole server surface of a folder delete is one DELETE followed by one
  /// organization fetch — in that order, and with no placement write anywhere.
  ///
  /// This replaces an earlier client-side workaround that wrote the promoted
  /// placements itself *before* issuing the DELETE, because the server used to
  /// scatter them to the root. The server now promotes them, so those writes
  /// would duplicate its work, and the non-atomic window between them was the
  /// reason the behaviour moved server-side at all.
  func testFolderDeleteIssuesOnlyADeleteThenARefetch() async throws {
    let parentServerId = PlaylistFolderNanoidFixture.make()
    let rockServerId = PlaylistFolderNanoidFixture.make()
    seedLocalFolder(serverId: parentServerId, name: "Parent")
    seedLocalFolder(serverId: rockServerId, name: "Rock", parentId: parentServerId)
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    let serverCallLog = ServerCallLog()
    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      organizationFetcher: {
        serverCallLog.record("fetchOrganization")
        // The server's post-delete truth: Rock is gone, its playlist promoted.
        return NavidromeFolderOrganizationResponse(
          folderApiVersion: 2,
          folders: [
            NavidromeOrganizationFolder(id: parentServerId, name: "Parent", parentId: ""),
          ],
          placements: [
            NavidromeOrganizationPlacement(
              playlistId: "pl-1", folderId: parentServerId, sortOrder: 70
            ),
          ]
        )
      },
      folderDeleteRequester: { folderId in
        serverCallLog.record("deleteFolder:\(folderId)")
      }
    )
    let rockFolderId = rockServerId
    store.addPlaylists(["pl-1"], to: rockFolderId)

    let convergenceExpectation = expectationForDeleteConvergence()
    store.deleteFolder(id: rockFolderId)
    await fulfillment(of: [convergenceExpectation], timeout: 5)

    XCTAssertEqual(
      serverCallLog.recordedCalls,
      ["deleteFolder:\(rockServerId)", "fetchOrganization"],
      "Folder delete must issue no placement writes of its own"
    )
    // And it converged on the server's promotion.
    XCTAssertEqual(storedPlacementEdges(), ["pl-1@\(parentServerId)"])
    XCTAssertEqual(storedPlacementSortOrders()["pl-1@\(parentServerId)"], 70)
  }

  /// The case that makes local prediction unsafe: a playlist filed in both the
  /// folder and its parent. Promotion merges the two, the existing home wins, and
  /// the placement count goes *down* — so the client must take the server's word
  /// for the outcome rather than computing one.
  func testFolderDeleteConvergesOnServerPromotionEvenWhenPlacementCountDrops()
    async throws {
    let parentServerId = PlaylistFolderNanoidFixture.make()
    let rockServerId = PlaylistFolderNanoidFixture.make()
    seedLocalFolder(serverId: parentServerId, name: "Parent")
    seedLocalFolder(serverId: rockServerId, name: "Rock", parentId: parentServerId)
    seedLocalPlaylist(id: "pl-1", name: "Riffs")

    store.configureForTesting(
      context: testContext,
      account: account.managedObject,
      organizationFetcher: {
        NavidromeFolderOrganizationResponse(
          folderApiVersion: 2,
          folders: [
            NavidromeOrganizationFolder(id: parentServerId, name: "Parent", parentId: ""),
          ],
          // Two placements became one, keeping the parent's own sortOrder.
          placements: [
            NavidromeOrganizationPlacement(
              playlistId: "pl-1", folderId: parentServerId, sortOrder: 40
            ),
          ]
        )
      },
      folderDeleteRequester: { _ in }
    )
    let parentFolderId = parentServerId
    let rockFolderId = rockServerId
    store.addPlaylists(["pl-1"], to: parentFolderId)
    store.addPlaylists(["pl-1"], to: rockFolderId)
    XCTAssertEqual(storedPlacementEdges().count, 2)

    let convergenceExpectation = expectationForDeleteConvergence()
    store.deleteFolder(id: rockFolderId)
    await fulfillment(of: [convergenceExpectation], timeout: 5)

    XCTAssertEqual(storedPlacementEdges(), ["pl-1@\(parentServerId)"])
    XCTAssertEqual(
      storedPlacementSortOrders()["pl-1@\(parentServerId)"], 40,
      "The surviving placement must keep the server's sortOrder, not a locally invented one"
    )
    XCTAssertEqual(storedFolderNames, ["Parent"])
  }

  /// The two deterministic parts of a delete are still applied immediately, so
  /// the UI does not wait on a round trip to stop showing a deleted folder.
  func testFolderDeleteAppliesTheDeterministicPartsLocallyStraightAway() async throws {
    let parentServerId = PlaylistFolderNanoidFixture.make()
    let rockServerId = PlaylistFolderNanoidFixture.make()
    seedLocalFolder(serverId: parentServerId, name: "Parent")
    seedLocalFolder(serverId: rockServerId, name: "Rock", parentId: parentServerId)
    seedLocalFolder(
      serverId: PlaylistFolderNanoidFixture.make(),
      name: "Metal",
      parentId: rockServerId
    )
    store.configureForTesting(context: testContext, account: account.managedObject)

    store.deleteFolder(id: rockServerId)

    XCTAssertEqual(storedFolderNames, ["Metal", "Parent"])
    let parentFolder = try XCTUnwrap(store.folders.first { $0.name == "Parent" })
    XCTAssertEqual(
      parentFolder.subfolders.map(\.name), ["Metal"],
      "Child folders re-parent one level, which the contract guarantees"
    )
  }

  /// With no server configured there is nothing to converge to, so the delete
  /// must not leave edges pointing at a folder that no longer exists.
  func testFolderDeleteDropsEdgesIntoTheDeletedFolder() async throws {
    seedLocalPlaylist(id: "pl-1", name: "Riffs")
    let folder = store.createFolderForTesting(
      context: testContext, account: account, name: "Rock"
    )
    store.addPlaylists(["pl-1"], to: folder.id)
    XCTAssertEqual(storedPlacementEdges().count, 1)

    store.deleteFolder(id: folder.id)

    XCTAssertTrue(storedPlacementEdges().isEmpty)
    XCTAssertNotNil(
      library.getPlaylists(for: account).first { $0.id == "pl-1" },
      "Deleting a folder must never reach through to a playlist"
    )
  }

  // MARK: - 8. Legacy membership backfill

  /// Pre-v2 devices stored memberships in a bare many-to-many join. Dropping it
  /// at migration would have been schema-clean and would have silently discarded
  /// every existing device's folder organization.
  func testLegacyMembershipsAreCarriedOverToPlacements() async throws {
    let folderMO = seedLocalFolder(serverId: "folder-rock", name: "Rock")
    let firstPlaylist = seedLocalPlaylist(id: "pl-b", name: "Bravo")
    let secondPlaylist = seedLocalPlaylist(id: "pl-a", name: "Alpha")
    folderMO.addToPlaylists(firstPlaylist.managedObject)
    folderMO.addToPlaylists(secondPlaylist.managedObject)
    try? testContext.save()

    store.configure(
      context: testContext,
      navidromeApi: nil,
      account: account.managedObject
    )

    XCTAssertEqual(storedPlacementEdges(), ["pl-a@folder-rock", "pl-b@folder-rock"])
    // Carried-over edges get a stable order, taken from the name order the
    // pre-v2 UI displayed.
    XCTAssertEqual(store.folders.first?.playlistIds, ["pl-a", "pl-b"])
  }

  /// The backfill must not resurrect memberships a user has since removed, so it
  /// only runs while there are no placements at all.
  func testBackfillDoesNotRunWhenPlacementsAlreadyExist() async throws {
    let folderMO = seedLocalFolder(serverId: "folder-rock", name: "Rock")
    let legacyPlaylist = seedLocalPlaylist(id: "pl-legacy", name: "Legacy")
    let currentPlaylist = seedLocalPlaylist(id: "pl-current", name: "Current")
    folderMO.addToPlaylists(legacyPlaylist.managedObject)

    let placementMO = PlaylistFolderPlacementMO(context: testContext)
    placementMO.playlist = currentPlaylist.managedObject
    placementMO.folderId = "folder-rock"
    placementMO.account = account.managedObject
    try? testContext.save()

    store.configure(
      context: testContext,
      navidromeApi: nil,
      account: account.managedObject
    )

    XCTAssertEqual(storedPlacementEdges(), ["pl-current@folder-rock"])
  }
}

// MARK: - ServerCallLog

/// Records, in order, every server call a store makes through its injected
/// seams — so a test can assert on the calls that were *not* made.
private final class ServerCallLog: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = [String]()

  func record(_ call: String) {
    lock.lock()
    defer { lock.unlock() }
    calls.append(call)
  }

  var recordedCalls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}

// MARK: - Test seam

extension PlaylistFolderStore {
  /// Configure against a context and create a folder in one step, for tests that
  /// exercise the local write paths with no server attached.
  @discardableResult
  fileprivate func createFolderForTesting(
    context: NSManagedObjectContext,
    account: Account,
    name: String,
    parent: String? = nil
  )
    -> PlaylistFolder {
    configureForTesting(context: context, account: account.managedObject)
    return createFolder(name: name, parent: parent)
  }
}
