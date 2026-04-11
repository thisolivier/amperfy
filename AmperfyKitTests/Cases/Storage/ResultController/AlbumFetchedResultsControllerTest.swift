//
//  AlbumFetchedResultsControllerTest.swift
//  AmperfyKitTests
//
//  Created by implementer-amperfy on 2026-04-11.
//  Copyright (c) 2026 Amperfy. All rights reserved.
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

/// Regression guard for Bug B-1 (QA report 2026-04-11): the Home tab
/// "Newest Albums" section surfaced 1-track releases such as `God's Son`,
/// `Sleepless`, and `The Claw` — i.e. the `wholeAlbumsOnly: true`
/// constraint that `HomeManager` passed at init time was being silently
/// destroyed the moment `HomeManager` called
/// `search(displayFilter: .newest)`.
///
/// The underlying mechanism is in `BasicFetchedResultsController.search(predicate:)`
/// (and the `CachedFetchedResultsController` override): both assignments
/// destructively replace `fetchRequest.predicate` with whatever the caller
/// passes, so the init-time `wholeAlbumsOnly` clause only survived for the
/// `showAllResults()` path (which reads `defaultPredicate`). Any filtered
/// search — including the always-non-`.all` displayFilter Home uses —
/// dropped the whole-album constraint.
///
/// The fix (see `AlbumFetchedResultsController` in
/// `FetchedResultsControllers.swift`) stores the whole-album sub-predicate
/// at init time and overrides `search(predicate:)` to AND-compose it back
/// into every incoming predicate before delegating to `super`. These tests
/// exercise the Home-tab code path end to end against an in-memory Core
/// Data stack: they seed a 1-track album tagged "newest" alongside a
/// 5-track album tagged "newest", construct the FRC with
/// `wholeAlbumsOnly: true`, and assert the 1-track album is NOT in the
/// result set after a `.newest` search.
@MainActor
class AlbumFetchedResultsControllerTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var coreDataCompanion: CoreDataCompanion!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    coreDataCompanion = CoreDataCompanion(context: testContext)
    // The cached FRC variants use a disk-backed NSFetchedResultsController
    // cache keyed by account hash. Wipe it so stale entries from an earlier
    // test run cannot shadow the in-memory store's results.
    AlbumFetchedResultsController.deleteCache()
  }

  override func tearDown() {
    AlbumFetchedResultsController.deleteCache()
  }

  // MARK: - Helpers

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  /// Seeds an album that will be picked up by the `.newest` display filter
  /// (`newestIndex > 0`) with the requested track-count and release-type
  /// metadata. The id prefix lets tests filter out anything the shared
  /// `CoreDataSeeder` may have inserted.
  @discardableResult
  private func makeNewestAlbum(
    id: String,
    releaseType: String?,
    remoteSongCount: Int,
    newestIndex: Int
  )
    -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.name = id
    album.releaseType = releaseType
    album.remoteSongCount = remoteSongCount
    album.updateIsNewestInfo(index: newestIndex)
    return album
  }

  /// The ids the FRC is currently exposing, filtered to ones this test
  /// case seeded.
  private func fetchedIds(
    _ controller: AlbumFetchedResultsController,
    withPrefix prefix: String
  )
    -> [String] {
    (controller.fetchedObjects ?? [])
      .compactMap { $0.id }
      .filter { $0.hasPrefix(prefix) }
      .sorted()
  }

  // MARK: - Tests

  /// **Primary B-1 regression guard.** Reproduces the exact Home-tab call
  /// sequence: construct an `AlbumFetchedResultsController` with
  /// `wholeAlbumsOnly: true`, then call
  /// `search(searchText:"", onlyCached:false, displayFilter:.newest)` —
  /// which routes through `BasicFetchedResultsController.search(predicate:)`
  /// and previously wiped the whole-album clause. A 1-track album tagged
  /// "newest" must NOT come back; the 5-track album must.
  func testWholeAlbumsOnlyFRCExcludesOneTrackAlbumAfterNewestSearch() {
    makeNewestAlbum(
      id: "b1-1track",
      releaseType: nil,
      remoteSongCount: 1,
      newestIndex: 1
    )
    makeNewestAlbum(
      id: "b1-5track",
      releaseType: nil,
      remoteSongCount: 5,
      newestIndex: 2
    )
    library.saveContext()

    let controller = AlbumFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .newest,
      isGroupedInAlphabeticSections: false,
      wholeAlbumsOnly: true
    )
    controller.search(searchText: "", onlyCached: false, displayFilter: .newest)

    let matched = fetchedIds(controller, withPrefix: "b1-")
    XCTAssertEqual(
      matched,
      ["b1-5track"],
      "1-track album must not leak through the Home 'Newest Albums' section once wholeAlbumsOnly is set"
    )
  }

  /// A `"single"`-tagged album with enough tracks to beat the count floor
  /// must still be excluded: metadata veto must survive the search path
  /// just as the count floor does.
  func testWholeAlbumsOnlyFRCExcludesSingleTaggedAlbumAfterNewestSearch() {
    makeNewestAlbum(
      id: "b1-single-5",
      releaseType: "single",
      remoteSongCount: 5,
      newestIndex: 1
    )
    makeNewestAlbum(
      id: "b1-album-5",
      releaseType: "album",
      remoteSongCount: 5,
      newestIndex: 2
    )
    library.saveContext()

    let controller = AlbumFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .newest,
      isGroupedInAlphabeticSections: false,
      wholeAlbumsOnly: true
    )
    controller.search(searchText: "", onlyCached: false, displayFilter: .newest)

    let matched = fetchedIds(controller, withPrefix: "b1-")
    XCTAssertEqual(
      matched,
      ["b1-album-5"],
      "'single'-tagged albums must be excluded even with enough tracks to clear the count floor"
    )
  }

  /// When `wholeAlbumsOnly` is false, the override is a no-op and the
  /// 1-track album must still come back (so the override is not silently
  /// over-filtering non-whole-album consumers).
  func testNonWholeAlbumsFRCIncludesOneTrackAlbumAfterNewestSearch() {
    makeNewestAlbum(
      id: "b1b-1track",
      releaseType: nil,
      remoteSongCount: 1,
      newestIndex: 1
    )
    makeNewestAlbum(
      id: "b1b-5track",
      releaseType: nil,
      remoteSongCount: 5,
      newestIndex: 2
    )
    library.saveContext()

    let controller = AlbumFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .newest,
      isGroupedInAlphabeticSections: false,
      wholeAlbumsOnly: false
    )
    controller.search(searchText: "", onlyCached: false, displayFilter: .newest)

    let matched = fetchedIds(controller, withPrefix: "b1b-")
    XCTAssertEqual(
      matched,
      ["b1b-1track", "b1b-5track"],
      "Override must pass through unchanged when wholeAlbumsOnly is false"
    )
  }

  /// The fix must also cover the bare `search(predicate:)` entry point,
  /// not just the `searchText`/`displayFilter` façade, so any future
  /// caller that passes a predicate directly still has the whole-album
  /// clause AND-composed in.
  func testWholeAlbumsOnlyFRCComposesWithRawSearchPredicate() {
    makeNewestAlbum(
      id: "b1c-1track",
      releaseType: nil,
      remoteSongCount: 1,
      newestIndex: 1
    )
    makeNewestAlbum(
      id: "b1c-5track",
      releaseType: nil,
      remoteSongCount: 5,
      newestIndex: 2
    )
    library.saveContext()

    let controller = AlbumFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .newest,
      isGroupedInAlphabeticSections: false,
      wholeAlbumsOnly: true
    )
    // Raw predicate a caller might pass: "newestIndex > 0". Under the old
    // destructive-replace behavior this would return both albums; the
    // override must AND-compose the whole-album clause back in.
    let rawPredicate = NSPredicate(format: "%K > 0", #keyPath(AlbumMO.newestIndex))
    controller.search(predicate: rawPredicate)

    let matched = fetchedIds(controller, withPrefix: "b1c-")
    XCTAssertEqual(
      matched,
      ["b1c-5track"],
      "search(predicate:) must compose the whole-album clause with the incoming predicate"
    )
  }
}
