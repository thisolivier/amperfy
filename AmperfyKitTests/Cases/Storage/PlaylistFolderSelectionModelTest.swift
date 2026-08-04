//
//  PlaylistFolderSelectionModelTest.swift
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

// MARK: - PlaylistFolderSelectionModelTest

/// Tests for the selection model behind command-click, shift-click ranges and
/// keyboard focus.
///
/// These are the behaviours that are tedious and error-prone to check by hand on
/// a Mac — a shift-click that ratchets its anchor, a selection that survives a
/// reload it should not have survived — so they are pinned here instead.
class PlaylistFolderSelectionModelTest: XCTestCase {
  private var model = PlaylistFolderSelectionModel()

  override func setUp() {
    super.setUp()
    model = PlaylistFolderSelectionModel()
  }

  // MARK: - Plain click

  func testPlainClickReplacesTheSelection() {
    model.applyGesture(.replace, atRowIndex: 3)
    model.applyGesture(.replace, atRowIndex: 5)
    XCTAssertEqual(model.selectedRowIndices, [5])
    XCTAssertEqual(model.anchorRowIndex, 5)
    XCTAssertEqual(model.focusedRowIndex, 5)
  }

  // MARK: - Command-click

  func testCommandClickTogglesWithoutDisturbingTheRest() {
    model.applyGesture(.replace, atRowIndex: 1)
    model.applyGesture(.toggle, atRowIndex: 4)
    model.applyGesture(.toggle, atRowIndex: 6)
    XCTAssertEqual(model.selectedRowIndices, [1, 4, 6])

    model.applyGesture(.toggle, atRowIndex: 4)
    XCTAssertEqual(model.selectedRowIndices, [1, 6])
  }

  func testCommandClickReanchorsSoAFollowingShiftClickExtendsFromIt() {
    model.applyGesture(.replace, atRowIndex: 0)
    model.applyGesture(.toggle, atRowIndex: 5)
    model.applyGesture(.extendFromAnchor, atRowIndex: 7)
    XCTAssertEqual(model.selectedRowIndices, [5, 6, 7])
  }

  // MARK: - Shift-click

  func testShiftClickSelectsTheInclusiveRangeInBothDirections() {
    model.applyGesture(.replace, atRowIndex: 4)
    model.applyGesture(.extendFromAnchor, atRowIndex: 7)
    XCTAssertEqual(model.selectedRowIndices, [4, 5, 6, 7])

    model.applyGesture(.extendFromAnchor, atRowIndex: 1)
    XCTAssertEqual(model.selectedRowIndices, [1, 2, 3, 4])
  }

  func testShiftClickKeepsItsAnchorSoTheSweepCanBeRedone() {
    model.applyGesture(.replace, atRowIndex: 4)
    model.applyGesture(.extendFromAnchor, atRowIndex: 8)
    model.applyGesture(.extendFromAnchor, atRowIndex: 6)
    // Re-sweeping from the same origin, not ratcheting from row 8.
    XCTAssertEqual(model.selectedRowIndices, [4, 5, 6])
    XCTAssertEqual(model.anchorRowIndex, 4)
  }

  func testShiftClickWithNoAnchorActsLikeAPlainClick() {
    model.applyGesture(.extendFromAnchor, atRowIndex: 3)
    XCTAssertEqual(model.selectedRowIndices, [3])
    XCTAssertEqual(model.anchorRowIndex, 3)
  }

  // MARK: - Select all / clear

  func testSelectAllAndClear() {
    model.selectAllRows(rowCount: 4)
    XCTAssertEqual(model.selectedRowIndices, [0, 1, 2, 3])
    XCTAssertEqual(model.selectedRowCount, 4)

    model.clearSelection()
    XCTAssertTrue(model.isEmpty)
    XCTAssertNil(model.anchorRowIndex)
  }

  func testSelectAllOnAnEmptyListDoesNothing() {
    model.selectAllRows(rowCount: 0)
    XCTAssertTrue(model.isEmpty)
  }

  func testOrderedSelectionIsInListOrder() {
    model.applyGesture(.toggle, atRowIndex: 7)
    model.applyGesture(.toggle, atRowIndex: 2)
    model.applyGesture(.toggle, atRowIndex: 5)
    XCTAssertEqual(model.orderedSelectedRowIndices, [2, 5, 7])
  }

  // MARK: - Reconcile after reload

  func testReconcileDropsRowsThatNoLongerExist() {
    model.selectAllRows(rowCount: 6)
    model.reconcile(rowCount: 3)
    XCTAssertEqual(model.selectedRowIndices, [0, 1, 2])
  }

  func testReconcileClearsAStaleAnchorAndPullsFocusBackIntoRange() {
    model.applyGesture(.replace, atRowIndex: 5)
    model.reconcile(rowCount: 2)
    XCTAssertNil(model.anchorRowIndex)
    XCTAssertEqual(model.focusedRowIndex, 1)
  }

  func testReconcileToAnEmptyListClearsFocusEntirely() {
    model.applyGesture(.replace, atRowIndex: 2)
    model.reconcile(rowCount: 0)
    XCTAssertTrue(model.isEmpty)
    XCTAssertNil(model.focusedRowIndex)
  }

  // MARK: - Keyboard focus

  func testFocusStartsAtTheTopGoingDownAndTheBottomGoingUp() {
    var downwardModel = PlaylistFolderSelectionModel()
    XCTAssertEqual(downwardModel.moveFocus(by: 1, rowCount: 5), 0)

    var upwardModel = PlaylistFolderSelectionModel()
    XCTAssertEqual(upwardModel.moveFocus(by: -1, rowCount: 5), 4)
  }

  func testFocusClampsAtBothEnds() {
    model.setFocusedRowIndex(0)
    XCTAssertEqual(model.moveFocus(by: -1, rowCount: 3), 0)
    model.setFocusedRowIndex(2)
    XCTAssertEqual(model.moveFocus(by: 1, rowCount: 3), 2)
  }

  func testFocusOnAnEmptyListIsNil() {
    model.setFocusedRowIndex(0)
    XCTAssertNil(model.moveFocus(by: 1, rowCount: 0))
    XCTAssertNil(model.focusedRowIndex)
  }
}

// MARK: - PlaylistFolderModifierKeyStateTest

/// Which gesture a click carries under the modifier keys currently held.
class PlaylistFolderModifierKeyStateTest: XCTestCase {
  func testNoModifiersMeansAPlainClickThatNavigates() {
    let state = PlaylistFolderModifierKeyState()
    XCTAssertEqual(state.selectionGesture, .replace)
    XCTAssertFalse(state.isSelectionModifierHeld)
  }

  func testCommandTogglesAndShiftExtends() {
    var commandState = PlaylistFolderModifierKeyState()
    commandState.setCommandKeyDown(true)
    XCTAssertEqual(commandState.selectionGesture, .toggle)
    XCTAssertTrue(commandState.isSelectionModifierHeld)

    var shiftState = PlaylistFolderModifierKeyState()
    shiftState.setShiftKeyDown(true)
    XCTAssertEqual(shiftState.selectionGesture, .extendFromAnchor)
    XCTAssertTrue(shiftState.isSelectionModifierHeld)
  }

  func testShiftWinsWhenBothAreHeld() {
    var state = PlaylistFolderModifierKeyState()
    state.setCommandKeyDown(true)
    state.setShiftKeyDown(true)
    XCTAssertEqual(state.selectionGesture, .extendFromAnchor)
  }

  func testResetClearsEverything() {
    var state = PlaylistFolderModifierKeyState()
    state.setCommandKeyDown(true)
    state.setShiftKeyDown(true)
    state.reset()
    XCTAssertFalse(state.isSelectionModifierHeld)
    XCTAssertEqual(state.selectionGesture, .replace)
  }
}
