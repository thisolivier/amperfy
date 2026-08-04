//
//  PlaylistFolderAdoptionTest.swift
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
import XCTest

/// The adoption payload and the screen-scope binding built on it.
///
/// The binding is a value type rather than logic inside the browse view
/// controller precisely so it can be tested here: `AmperfyKitTests` cannot see
/// the app target, and "rebind on a match, ignore everything else" is the part
/// worth pinning.
class PlaylistFolderAdoptionTest: XCTestCase {
  private let temporaryId = "pending-local:2B0F1C24-0000-0000-0000-00000000ABCD"
  private let serverId = "Wq3nT7yZ0aB5cD8eF1gH2i"

  // MARK: - Notification payload

  func testTheAdoptionPayloadRoundTripsThroughANotification() {
    let adoption = PlaylistFolderAdoption(
      temporaryFolderId: temporaryId,
      serverFolderId: serverId
    )
    let notification = Notification(
      name: PlaylistFolderStore.didAdoptFolderIdNotification,
      object: nil,
      userInfo: adoption.asNotificationUserInfo
    )
    XCTAssertEqual(PlaylistFolderAdoption.fromNotification(notification), adoption)
  }

  func testAnAdoptionCannotBeReadOutOfAnUnrelatedNotification() {
    let notification = Notification(
      name: PlaylistFolderStore.didChangeNotification,
      object: nil,
      userInfo: nil
    )
    XCTAssertNil(PlaylistFolderAdoption.fromNotification(notification))

    let malformedNotification = Notification(
      name: PlaylistFolderStore.didAdoptFolderIdNotification,
      object: nil,
      userInfo: ["temporaryFolderId": temporaryId]
    )
    XCTAssertNil(PlaylistFolderAdoption.fromNotification(malformedNotification))
  }

  // MARK: - Scope binding

  func testAScopedScreenRebindsWhenItsOwnFolderAdopts() {
    var binding = PlaylistFolderScopeBinding(scopedFolderId: temporaryId)
    let didRebind = binding.apply(PlaylistFolderAdoption(
      temporaryFolderId: temporaryId,
      serverFolderId: serverId
    ))

    // Without this the screen's next reload finds no such folder and pops the
    // user out of a folder they are working in.
    XCTAssertTrue(didRebind)
    XCTAssertEqual(binding.scopedFolderId, serverId)
  }

  func testAScreenScopedElsewhereIgnoresTheAdoption() {
    let otherTemporaryId = "pending-local:FFFFFFFF-0000-0000-0000-00000000FFFF"
    var binding = PlaylistFolderScopeBinding(scopedFolderId: otherTemporaryId)
    let didRebind = binding.apply(PlaylistFolderAdoption(
      temporaryFolderId: temporaryId,
      serverFolderId: serverId
    ))

    XCTAssertFalse(didRebind)
    XCTAssertEqual(binding.scopedFolderId, otherTemporaryId)
  }

  func testTheRootBindingNeverRebinds() {
    var binding = PlaylistFolderScopeBinding(scopedFolderId: nil)
    let didRebind = binding.apply(PlaylistFolderAdoption(
      temporaryFolderId: temporaryId,
      serverFolderId: serverId
    ))

    // The root has no id, so nothing can adopt on its behalf.
    XCTAssertFalse(didRebind)
    XCTAssertNil(binding.scopedFolderId)
  }

  func testRebindingIsIdempotentAgainstARepeatedEvent() {
    var binding = PlaylistFolderScopeBinding(scopedFolderId: temporaryId)
    let adoption = PlaylistFolderAdoption(
      temporaryFolderId: temporaryId,
      serverFolderId: serverId
    )
    XCTAssertTrue(binding.apply(adoption))
    // The second delivery no longer matches, so it cannot walk the binding
    // backwards or trigger a needless reload.
    XCTAssertFalse(binding.apply(adoption))
    XCTAssertEqual(binding.scopedFolderId, serverId)
  }
}
