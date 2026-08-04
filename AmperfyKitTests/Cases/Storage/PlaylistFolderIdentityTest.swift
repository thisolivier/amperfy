//
//  PlaylistFolderIdentityTest.swift
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

/// Folder identity is an opaque, case-sensitive server string.
///
/// The client used to hold it as a `UUID`, parsed out of the stored id with
/// `UUID(uuidString: folderMO.id) ?? UUID()`. Navidrome mints folder ids with
/// `id.NewRandom()` — a 22-character nanoid over `[0-9A-Za-z]` — so against the
/// real server that parse failed for *every* folder and the fallback minted a
/// fresh random UUID each time the tree was rebuilt. The id the UI then handed
/// back matched nothing, and every move, rename and delete was a silent no-op.
///
/// These tests pin the properties that failure violated, using ids shaped the
/// way the server actually makes them.
@MainActor
class PlaylistFolderIdentityTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PlaylistFolderStore!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PlaylistFolderStore(defaults: UserDefaults(suiteName: "\(UUID().uuidString)")!)
    store.configureForTesting(context: testContext, account: account.managedObject)
  }

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  @discardableResult
  private func seedServerFolder(
    id: String,
    name: String,
    parentId: String? = nil
  )
    -> PlaylistFolderMO {
    let folderMO = PlaylistFolderMO(context: testContext)
    folderMO.id = id
    folderMO.name = name
    folderMO.parentId = parentId
    folderMO.account = account.managedObject
    try? testContext.save()
    return folderMO
  }

  @discardableResult
  private func seedPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    try? testContext.save()
    return playlist
  }

  // MARK: - The id survives the tree

  func testServerNanoidIdIsCarriedThroughTheFolderTreeVerbatim() {
    let serverId = PlaylistFolderNanoidFixture.make()
    seedServerFolder(id: serverId, name: "Rock")

    // The regression: this used to be a freshly minted UUID, different on every
    // read, because the nanoid could not be parsed.
    XCTAssertEqual(store.folders.first?.id, serverId)
  }

  func testTheSameFolderReadTwiceHasTheSameId() {
    seedServerFolder(id: PlaylistFolderNanoidFixture.make(), name: "Rock")
    XCTAssertEqual(store.folders.first?.id, store.folders.first?.id)
    XCTAssertNotNil(store.folder(byId: try! XCTUnwrap(store.folders.first?.id)))
  }

  func testAFolderIsFoundByTheIdTheTreeHandedOut() {
    let serverId = PlaylistFolderNanoidFixture.make()
    seedServerFolder(id: serverId, name: "Rock")
    let idFromTree = store.folders.first?.id
    XCTAssertEqual(store.folder(byId: try! XCTUnwrap(idFromTree))?.name, "Rock")
  }

  func testNanoidIdsAreNotParseableAsUUIDs() {
    // Guards the fixture itself: if these ever became UUID-shaped, the tests
    // above would stop covering the case that actually broke.
    for _ in 0 ..< 20 {
      let id = PlaylistFolderNanoidFixture.make()
      XCTAssertEqual(id.count, 22)
      XCTAssertNil(UUID(uuidString: id))
    }
  }

  // MARK: - Case sensitivity

  func testTwoIdsDifferingOnlyInCaseAreDifferentFolders() {
    let lowerCaseId = "abcdefghijklmnopqrstuv"
    let upperCaseId = "ABCDEFGHIJKLMNOPQRSTUV"
    seedServerFolder(id: lowerCaseId, name: "Lower")
    seedServerFolder(id: upperCaseId, name: "Upper")

    XCTAssertEqual(store.folder(byId: lowerCaseId)?.name, "Lower")
    XCTAssertEqual(store.folder(byId: upperCaseId)?.name, "Upper")
  }

  func testRenamingOneOfTwoCaseTwinsLeavesTheOtherAlone() {
    let lowerCaseId = "abcdefghijklmnopqrstuv"
    let upperCaseId = "ABCDEFGHIJKLMNOPQRSTUV"
    seedServerFolder(id: lowerCaseId, name: "Lower")
    seedServerFolder(id: upperCaseId, name: "Upper")

    store.renameFolder(id: lowerCaseId, to: "Renamed")

    XCTAssertEqual(store.folder(byId: lowerCaseId)?.name, "Renamed")
    // A case-insensitive lookup would have renamed whichever matched first.
    XCTAssertEqual(store.folder(byId: upperCaseId)?.name, "Upper")
  }

  func testDeletingOneOfTwoCaseTwinsLeavesTheOtherAlone() {
    let lowerCaseId = "abcdefghijklmnopqrstuv"
    let upperCaseId = "ABCDEFGHIJKLMNOPQRSTUV"
    seedServerFolder(id: lowerCaseId, name: "Lower")
    seedServerFolder(id: upperCaseId, name: "Upper")

    store.deleteFolder(id: upperCaseId)

    XCTAssertNil(store.folder(byId: upperCaseId))
    XCTAssertEqual(store.folder(byId: lowerCaseId)?.name, "Lower")
  }

  func testPlacementsGoToTheExactCasedFolder() {
    let lowerCaseId = "abcdefghijklmnopqrstuv"
    let upperCaseId = "ABCDEFGHIJKLMNOPQRSTUV"
    seedServerFolder(id: lowerCaseId, name: "Lower")
    seedServerFolder(id: upperCaseId, name: "Upper")
    seedPlaylist(id: "pl-1", name: "Playlist 1")

    store.addPlaylists(["pl-1"], to: upperCaseId)

    XCTAssertEqual(store.folder(byId: upperCaseId)?.playlistIds, ["pl-1"])
    XCTAssertEqual(store.folder(byId: lowerCaseId)?.playlistIds, [])
  }

  // MARK: - Mutations against server-shaped ids

  func testMoveRenameAndDeleteAllTakeEffectAgainstNanoidIds() {
    let parentId = PlaylistFolderNanoidFixture.make()
    let childId = PlaylistFolderNanoidFixture.make()
    seedServerFolder(id: parentId, name: "Parent")
    seedServerFolder(id: childId, name: "Child")

    store.moveFolder(id: childId, toParent: parentId)
    XCTAssertEqual(store.folder(byId: parentId)?.subfolders.map(\.name), ["Child"])

    store.renameFolder(id: childId, to: "Renamed")
    XCTAssertEqual(store.folder(byId: parentId)?.subfolders.map(\.name), ["Renamed"])

    store.deleteFolder(id: childId)
    XCTAssertEqual(store.folder(byId: parentId)?.subfolders, [])
  }

  func testBulkMoveWorksAgainstNanoidIds() {
    let sourceId = PlaylistFolderNanoidFixture.make()
    let destinationId = PlaylistFolderNanoidFixture.make()
    seedServerFolder(id: sourceId, name: "Source")
    seedServerFolder(id: destinationId, name: "Destination")
    for index in 1 ... 3 { seedPlaylist(id: "pl-\(index)", name: "Playlist \(index)") }
    store.addPlaylists(["pl-1", "pl-2", "pl-3"], to: sourceId)

    store.movePlaylists(["pl-1", "pl-2", "pl-3"], from: sourceId, to: destinationId)

    XCTAssertEqual(store.folder(byId: sourceId)?.playlistIds, [])
    XCTAssertEqual(store.folder(byId: destinationId)?.playlistIds, ["pl-1", "pl-2", "pl-3"])
  }

  func testReorderingASiblingWorksAgainstNanoidIds() {
    let firstId = PlaylistFolderNanoidFixture.make()
    let secondId = PlaylistFolderNanoidFixture.make()
    seedServerFolder(id: firstId, name: "First")
    seedServerFolder(id: secondId, name: "Second")
    store.moveSibling(kind: .folder, id: firstId, inFolder: nil, toIndex: 0)
    store.moveSibling(kind: .folder, id: secondId, inFolder: nil, toIndex: 1)

    store.moveSibling(kind: .folder, id: secondId, inFolder: nil, toIndex: 0)

    XCTAssertEqual(store.orderedSiblings(inFolder: nil).map(\.id), [secondId, firstId])
  }

  func testAnEmptyFolderIdIsTheRootAndNeverAFolder() {
    seedServerFolder(id: PlaylistFolderNanoidFixture.make(), name: "Rock")
    // The empty string is the root sentinel on placements; it must never resolve
    // to a folder row, or a placement at root would be read as filed.
    XCTAssertNil(store.folder(byId: ""))
  }

  // MARK: - Temporary id replaced by the server's

  func testALocallyCreatedFolderGetsATemporaryIdThatIsNotServerShaped() {
    let folder = store.createFolder(name: "Fresh", parent: nil)
    XCTAssertNotEqual(folder.id.count, PlaylistFolderNanoidFixture.idLength)
    // A UUID string cannot be mistaken for a nanoid, so the two id spaces never
    // overlap while a create is in flight.
    XCTAssertNotNil(UUID(uuidString: folder.id))
    XCTAssertEqual(store.folder(byId: folder.id)?.name, "Fresh")
  }

  func testTheServerIdReplacesTheTemporaryOneAndCarriesEverythingAcross() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let createdFolder = store.createFolder(name: "Fresh", parent: nil)
    let temporaryId = createdFolder.id
    // Work done against the optimistic folder before its POST returns.
    store.addPlaylists(["pl-1"], to: temporaryId)
    let childFolder = store.createFolder(name: "Child", parent: temporaryId)

    // What the create callback does once the server answers.
    let serverId = PlaylistFolderNanoidFixture.make()
    let folderMO = try! XCTUnwrap(store.fetchFolderMO(byServerId: temporaryId, in: testContext))
    folderMO.id = serverId
    store.repointFolderReferences(from: temporaryId, to: serverId, in: testContext)
    try? testContext.save()

    XCTAssertNil(store.folder(byId: temporaryId), "the temporary id must stop resolving")
    let adoptedFolder = try! XCTUnwrap(store.folder(byId: serverId))
    XCTAssertEqual(adoptedFolder.name, "Fresh")
    // The placement and the child folder made against the temporary id follow it.
    XCTAssertEqual(adoptedFolder.playlistIds, ["pl-1"])
    XCTAssertEqual(adoptedFolder.subfolders.map(\.id), [childFolder.id])
  }

  func testTheExportRecordsTheServerIdAfterAdoption() {
    seedPlaylist(id: "pl-1", name: "Playlist 1")
    let createdFolder = store.createFolder(name: "Fresh", parent: nil)
    store.addPlaylists(["pl-1"], to: createdFolder.id)

    let serverId = PlaylistFolderNanoidFixture.make()
    let folderMO = try! XCTUnwrap(
      store.fetchFolderMO(byServerId: createdFolder.id, in: testContext)
    )
    folderMO.id = serverId
    store.repointFolderReferences(from: createdFolder.id, to: serverId, in: testContext)
    try? testContext.save()

    // The JSON safety net is the fallback if everything else is lost, so it has
    // to name the id the server knows, not the one that only ever existed here.
    let export = store.buildExport(from: testContext)
    XCTAssertEqual(export.folders.map(\.id), [serverId])
    XCTAssertEqual(export.placements.map(\.folderId), [serverId])
  }
}
