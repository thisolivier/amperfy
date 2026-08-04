//
//  PlaylistFolderSelectionModel.swift
//  AmperfyKit
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

import Foundation

// MARK: - PlaylistFolderSelectionGesture

/// How a click on a browse row should change the selection. Named after what the
/// user did rather than which modifier was held, so the table view controller is
/// the only place that has to know about `UIKeyModifierFlags`.
public enum PlaylistFolderSelectionGesture: Sendable, Equatable {
  /// Plain click: this row becomes the whole selection, and the new anchor.
  case replace
  /// Command-click: toggle this row, leaving the rest of the selection alone.
  case toggle
  /// Shift-click: select every row between the anchor and this one.
  case extendFromAnchor
}

// MARK: - PlaylistFolderSelectionModel

/// The selection state behind the interleaved browse list.
///
/// Selection lives here rather than in `UITableView.indexPathsForSelectedRows`
/// because the rebuild the owner is doing is a Mac session: command-click,
/// shift-click ranges and keyboard focus all need an anchor and a focused row,
/// neither of which UIKit's table selection carries. The table view is driven
/// *from* this model, not read as the source of truth.
///
/// Rows are addressed by index into the current row list. `reconcile(rowCount:)`
/// must be called after any reload that can change the list length.
public struct PlaylistFolderSelectionModel: Equatable, Sendable {
  public private(set) var selectedRowIndices: Set<Int> = []
  /// The row a shift-click extends from — the last row clicked without shift.
  public private(set) var anchorRowIndex: Int?
  /// The row the keyboard is on. Arrow keys move it; it is not itself a
  /// selection, so a user can walk the list and then press space/return.
  public private(set) var focusedRowIndex: Int?

  public init() {}

  public var isEmpty: Bool { selectedRowIndices.isEmpty }
  public var selectedRowCount: Int { selectedRowIndices.count }

  /// Selected rows in list order — the order every bulk operation applies in.
  public var orderedSelectedRowIndices: [Int] { selectedRowIndices.sorted() }

  // MARK: - Click handling

  /// Apply a click on `rowIndex` under `gesture`.
  public mutating func applyGesture(
    _ gesture: PlaylistFolderSelectionGesture,
    atRowIndex rowIndex: Int
  ) {
    focusedRowIndex = rowIndex
    switch gesture {
    case .replace:
      selectedRowIndices = [rowIndex]
      anchorRowIndex = rowIndex

    case .toggle:
      if selectedRowIndices.contains(rowIndex) {
        selectedRowIndices.remove(rowIndex)
      } else {
        selectedRowIndices.insert(rowIndex)
      }
      // A command-click re-anchors, so a following shift-click extends from the
      // row the user last actually pointed at.
      anchorRowIndex = rowIndex

    case .extendFromAnchor:
      guard let anchorRowIndex else {
        // Nothing to extend from — behave like a plain click, which is also what
        // AppKit does for a shift-click into an empty selection.
        selectedRowIndices = [rowIndex]
        self.anchorRowIndex = rowIndex
        return
      }
      let lowerBound = min(anchorRowIndex, rowIndex)
      let upperBound = max(anchorRowIndex, rowIndex)
      selectedRowIndices = Set(lowerBound ... upperBound)
      // The anchor deliberately survives, so dragging the shift-click up and
      // down re-sweeps from the same origin instead of ratcheting.
    }
  }

  // MARK: - Bulk changes

  public mutating func selectAllRows(rowCount: Int) {
    guard rowCount > 0 else { return }
    selectedRowIndices = Set(0 ..< rowCount)
    anchorRowIndex = 0
    if focusedRowIndex == nil { focusedRowIndex = 0 }
  }

  public mutating func clearSelection() {
    selectedRowIndices = []
    anchorRowIndex = nil
  }

  public mutating func setSelectedRowIndices(_ rowIndices: Set<Int>) {
    selectedRowIndices = rowIndices
    if let anchorRowIndex, !rowIndices.contains(anchorRowIndex) {
      self.anchorRowIndex = rowIndices.min()
    }
  }

  /// Drop anything the current row list no longer contains. Called after every
  /// reload — rows vanish when a search narrows, when a bulk move empties a
  /// folder, or when the store reconciles from the server.
  public mutating func reconcile(rowCount: Int) {
    selectedRowIndices = selectedRowIndices.filter { $0 >= 0 && $0 < rowCount }
    if let anchorRowIndex, anchorRowIndex >= rowCount { self.anchorRowIndex = nil }
    if let focusedRowIndex, focusedRowIndex >= rowCount {
      self.focusedRowIndex = rowCount > 0 ? rowCount - 1 : nil
    }
  }

  // MARK: - Keyboard focus

  /// Move the focused row by `offset`, clamped to the list. With nothing focused
  /// yet, a downward move starts at the top and an upward move at the bottom, so
  /// the first arrow press always lands somewhere visible.
  ///
  /// - Returns: the newly focused row, or `nil` when the list is empty.
  @discardableResult
  public mutating func moveFocus(by offset: Int, rowCount: Int) -> Int? {
    guard rowCount > 0 else {
      focusedRowIndex = nil
      return nil
    }
    guard let currentFocusedRowIndex = focusedRowIndex else {
      focusedRowIndex = offset >= 0 ? 0 : rowCount - 1
      return focusedRowIndex
    }
    focusedRowIndex = min(max(currentFocusedRowIndex + offset, 0), rowCount - 1)
    return focusedRowIndex
  }

  public mutating func setFocusedRowIndex(_ rowIndex: Int?) {
    focusedRowIndex = rowIndex
  }
}

// MARK: - PlaylistFolderModifierKeyState

/// The modifier keys currently held down, tracked from `pressesBegan` /
/// `pressesEnded` so a click can be classified without UIKit handing the table
/// view an event that carries them.
///
/// Mac Catalyst delivers modifier-only key presses to the responder chain, which
/// is what makes this workable; on iPhone with no keyboard attached nothing ever
/// sets a flag and every click stays a plain `.replace`.
public struct PlaylistFolderModifierKeyState: Equatable, Sendable {
  public private(set) var isCommandKeyDown = false
  public private(set) var isShiftKeyDown = false

  public init() {}

  public mutating func setCommandKeyDown(_ isDown: Bool) { isCommandKeyDown = isDown }
  public mutating func setShiftKeyDown(_ isDown: Bool) { isShiftKeyDown = isDown }

  public mutating func reset() {
    isCommandKeyDown = false
    isShiftKeyDown = false
  }

  /// Which selection gesture a click carries under the current modifiers. Shift
  /// wins over command when both are held, matching Finder.
  public var selectionGesture: PlaylistFolderSelectionGesture {
    if isShiftKeyDown { return .extendFromAnchor }
    if isCommandKeyDown { return .toggle }
    return .replace
  }

  /// Whether a click should be treated as a selection change at all, rather than
  /// as navigation. Outside edit mode a plain click still navigates.
  public var isSelectionModifierHeld: Bool { isCommandKeyDown || isShiftKeyDown }
}
