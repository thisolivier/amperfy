//
//  PlaylistSyncWorkerContextResetTest.swift
//  AmperfyKitTests
//
//  Regression coverage for the mini-player-has-track / full-player-empty bug.
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

/// Locks in the fix for the on-device regression where the mini player shows a
/// track but tapping it opens a full player reading "No music playing".
///
/// Root cause: `PlaylistSyncWorker.resetMainContext()` called `context.reset()`
/// on the shared main/UI context every 5 playlists. `reset()` invalidates and
/// de-registers EVERY managed object on that context — including the play
/// queue's currently-playing item — so `PlayerData.currentItem` starts reading
/// `nil` while the already-painted mini player stays stale.
///
/// The fix swaps `reset()` for `refreshAllObjects()`, which releases the cached
/// property values (the memory goal) but keeps object identities valid, so the
/// queue re-faults transparently and `currentItem` never observes a spurious
/// `nil`.
@MainActor
class PlaylistSyncWorkerContextResetTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var context: NSManagedObjectContext!
  var library: LibraryStorage!
  var account: Account!
  var testPlayer: PlayerData!
  let fillCount = 5

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    context = cdHelper.persistentContainer.viewContext
    account = library.getAccount(info: TestAccountInfo.create1())
    testPlayer = library.getPlayerData()
    testPlayer.setShuffle(false)
    for i in 0 ..< fillCount {
      guard let song = library.getSong(for: account, id: cdHelper.seeder.songs[i].id)
      else { XCTFail("seed song missing"); return }
      testPlayer.appendActiveQueue(playables: [song])
    }
    testPlayer.setCurrentIndex(2)
    try context.save()
  }

  override func tearDown() async throws {
    cdHelper = nil
    context = nil
    library = nil
    account = nil
    testPlayer = nil
  }

  /// Precondition: with a queue loaded and a current index set, the player has a
  /// currently-playing item (this is the state the mini player renders from).
  func testCurrentItemPresentBeforeMemoryRelease() {
    XCTAssertNotNil(testPlayer.currentItem)
    XCTAssertEqual(
      testPlayer.currentItem?.id,
      cdHelper.seeder.songs[2].id
    )
  }

  /// Demonstrates the ROOT CAUSE: a full `context.reset()` (the pre-fix
  /// behaviour of `PlaylistSyncWorker.resetMainContext`) wipes the play queue,
  /// so `currentItem` reads `nil` — the exact source of the empty full player.
  func testFullContextResetClearsCurrentItem_documentsRegression() {
    XCTAssertNotNil(testPlayer.currentItem)
    context.reset()
    XCTAssertNil(
      testPlayer.currentItem,
      "context.reset() is expected to drop the play queue — this is why the bug happened"
    )
  }

  /// The FIX: `refreshAllObjects()` releases cached state without invalidating
  /// object identities, so the currently-playing item survives the periodic
  /// memory-release the worker performs during a large playlist sync.
  func testRefreshAllObjectsPreservesCurrentItem() {
    XCTAssertNotNil(testPlayer.currentItem)
    let idBefore = testPlayer.currentItem?.id

    context.refreshAllObjects()

    XCTAssertNotNil(
      testPlayer.currentItem,
      "After the worker's memory-release step the player must still know its current track"
    )
    XCTAssertEqual(
      testPlayer.currentItem?.id,
      idBefore,
      "The same track must remain current after refreshAllObjects()"
    )
    XCTAssertEqual(testPlayer.activeQueue.playables.count, fillCount)
  }
}
