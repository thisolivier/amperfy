//
//  PlaylistFolderContentsVC+Keyboard.swift
//  Amperfy
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

import AmperfyKit
import UIKit

/// Keyboard control of the browse list.
///
/// Two separate mechanisms, deliberately:
/// - `keyCommands` handles the shortcuts UIKit routes through the responder
///   chain. Select All and Delete use the standard `selectAll(_:)` /
///   `delete(_:)` responder selectors, so on Mac they land in the system Edit
///   menu without this screen having to build a menu; the rest are surfaced by
///   the Organize menu in `AppDelegateMainMenuExtension`.
/// - `pressesBegan` / `pressesEnded` track the modifier keys, because a click's
///   modifiers are not carried on anything `UITableViewDelegate` receives. This
///   is what makes command-click and shift-click ranges possible.
extension PlaylistFolderContentsVC {
  // MARK: - First responder

  override var canBecomeFirstResponder: Bool { true }

  // MARK: - Key commands

  override var keyCommands: [UIKeyCommand]? {
    let commands = [
      UIKeyCommand(
        title: "Move Down",
        action: #selector(keyboardMoveFocusDown),
        input: UIKeyCommand.inputDownArrow
      ),
      UIKeyCommand(
        title: "Move Up",
        action: #selector(keyboardMoveFocusUp),
        input: UIKeyCommand.inputUpArrow
      ),
      UIKeyCommand(
        title: "Extend Selection Down",
        action: #selector(keyboardExtendSelectionDown),
        input: UIKeyCommand.inputDownArrow,
        modifierFlags: .shift
      ),
      UIKeyCommand(
        title: "Extend Selection Up",
        action: #selector(keyboardExtendSelectionUp),
        input: UIKeyCommand.inputUpArrow,
        modifierFlags: .shift
      ),
      UIKeyCommand(
        title: "Open",
        action: #selector(keyboardOpenFocusedRow),
        input: UIKeyCommand.inputRightArrow
      ),
      UIKeyCommand(
        title: "Back",
        action: #selector(keyboardGoBack),
        input: UIKeyCommand.inputLeftArrow
      ),
      UIKeyCommand(
        title: "Rename\u{2026}",
        action: #selector(keyboardRenameFocusedRow),
        input: "\r"
      ),
      UIKeyCommand(
        title: "New Folder",
        action: #selector(keyboardNewFolder),
        input: "n",
        modifierFlags: .command
      ),
      UIKeyCommand(
        title: "New Folder from Selection\u{2026}",
        action: #selector(newFolderFromSelection),
        input: "n",
        modifierFlags: [.command, .shift]
      ),
      UIKeyCommand(
        title: "Move to Folder\u{2026}",
        action: #selector(moveSelectionToFolder),
        input: "m",
        modifierFlags: .command
      ),
      UIKeyCommand(
        title: "Deselect All",
        action: #selector(keyboardExitSelection),
        input: UIKeyCommand.inputEscape
      ),
      // The delete key is not a menu command, so it is wired here rather than
      // relying on the Edit menu's Delete item alone.
      UIKeyCommand(
        title: "Delete",
        action: #selector(delete(_:)),
        input: "\u{8}"
      ),
    ]
    for command in commands {
      // Keeps the shortcut out of the way when a text field (search, a rename
      // alert) legitimately wants the same key.
      command.wantsPriorityOverSystemBehavior = false
    }
    return commands
  }

  // MARK: - Standard responder actions

  /// Select All (⌘A). Overriding the standard selector puts it in the Mac Edit
  /// menu for free.
  override func selectAll(_ sender: Any?) {
    guard !displayedRows.isEmpty else { return }
    if !isEditing { setEditing(true, animated: true) }
    selectionModel.selectAllRows(rowCount: displayedRows.count)
    applySelectionToTableView()
  }

  /// Delete (⌫ / Edit ▸ Delete). Acts on the selection when there is one, and
  /// otherwise on the focused row.
  override func delete(_ sender: Any?) {
    if !selectionModel.isEmpty {
      deleteSelection()
      return
    }
    guard let focusedRowIndex = selectionModel.focusedRowIndex else { return }
    deleteRow(at: focusedRowIndex)
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    switch action {
    case #selector(selectAll(_:)):
      return !displayedRows.isEmpty
    case #selector(delete(_:)):
      return !selectionModel.isEmpty || selectionModel.focusedRowIndex != nil
    case #selector(addSelectionToFolder),
         #selector(moveSelectionToFolder),
         #selector(newFolderFromSelection),
         #selector(removeSelectionFromFolder):
      return !selectionModel.isEmpty
    default:
      return super.canPerformAction(action, withSender: sender)
    }
  }

  // MARK: - Focus movement

  @objc
  func keyboardMoveFocusDown() { moveFocus(by: 1) }

  @objc
  func keyboardMoveFocusUp() { moveFocus(by: -1) }

  private func moveFocus(by offset: Int) {
    guard let focusedRowIndex = selectionModel.moveFocus(
      by: offset,
      rowCount: displayedRows.count
    ) else { return }
    scrollToFocusedRow(focusedRowIndex)
    highlightFocusedRow(focusedRowIndex)
  }

  @objc
  func keyboardExtendSelectionDown() { extendSelection(by: 1) }

  @objc
  func keyboardExtendSelectionUp() { extendSelection(by: -1) }

  private func extendSelection(by offset: Int) {
    if !isEditing { setEditing(true, animated: true) }
    // The first shift-arrow needs an anchor; the focused row is it.
    if selectionModel.isEmpty, let focusedRowIndex = selectionModel.focusedRowIndex {
      selectionModel.applyGesture(.replace, atRowIndex: focusedRowIndex)
    }
    guard let focusedRowIndex = selectionModel.moveFocus(
      by: offset,
      rowCount: displayedRows.count
    ) else { return }
    selectionModel.applyGesture(.extendFromAnchor, atRowIndex: focusedRowIndex)
    applySelectionToTableView()
    scrollToFocusedRow(focusedRowIndex)
  }

  private func scrollToFocusedRow(_ rowIndex: Int) {
    guard displayedRows.indices.contains(rowIndex) else { return }
    tableView.scrollToRow(
      at: IndexPath(row: rowIndex, section: 0),
      at: .none,
      animated: true
    )
  }

  /// Outside edit mode there is no checkmark to show where the keyboard is, so
  /// the focused row is briefly highlighted instead.
  private func highlightFocusedRow(_ rowIndex: Int) {
    guard !isEditing else { return }
    let indexPath = IndexPath(row: rowIndex, section: 0)
    tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    tableView.deselectRow(at: indexPath, animated: true)
  }

  // MARK: - Activation

  @objc
  func keyboardOpenFocusedRow() {
    guard let focusedRowIndex = selectionModel.focusedRowIndex,
          let row = row(at: focusedRowIndex)
    else { return }
    switch row {
    case let .folder(folder):
      openFolder(folder)
    case let .playlist(playlist):
      onPlaylistSelected(playlist, at: IndexPath(row: focusedRowIndex, section: 0))
    }
  }

  @objc
  func keyboardGoBack() {
    navigationController?.popViewController(animated: true)
  }

  @objc
  func keyboardRenameFocusedRow() {
    // A single selected row is what the user means when they have been selecting
    // with the keyboard; otherwise fall back to the focused row.
    let rowIndex = selectionModel.selectedRowCount == 1
      ? selectionModel.orderedSelectedRowIndices[0]
      : selectionModel.focusedRowIndex
    guard let rowIndex, let row = row(at: rowIndex) else { return }
    switch row {
    case let .folder(folder): promptRenameFolder(folder)
    case let .playlist(playlist): promptRenamePlaylist(playlist)
    }
  }

  @objc
  func keyboardNewFolder() {
    promptCreateFolder()
  }

  @objc
  func keyboardExitSelection() {
    guard isEditing else { return }
    setEditing(false, animated: true)
  }

  // MARK: - Modifier key tracking

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    updateModifierKeyState(from: event)
    super.pressesBegan(presses, with: event)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    clearModifierKeys(releasedBy: presses)
    super.pressesEnded(presses, with: event)
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    modifierKeyState.reset()
    super.pressesCancelled(presses, with: event)
  }

  private func updateModifierKeyState(from event: UIPressesEvent?) {
    let modifierFlags = event?.modifierFlags ?? []
    modifierKeyState.setCommandKeyDown(modifierFlags.contains(.command))
    modifierKeyState.setShiftKeyDown(modifierFlags.contains(.shift))
  }

  /// Clear from the *released keys*, not from the event's flags: at the moment a
  /// modifier is released the event still reports it as held, so trusting the
  /// flags here would leave the state stuck down forever.
  private func clearModifierKeys(releasedBy presses: Set<UIPress>) {
    for press in presses {
      switch press.key?.keyCode {
      case .keyboardLeftGUI, .keyboardRightGUI:
        modifierKeyState.setCommandKeyDown(false)
      case .keyboardLeftShift, .keyboardRightShift:
        modifierKeyState.setShiftKeyDown(false)
      default:
        break
      }
    }
  }
}
