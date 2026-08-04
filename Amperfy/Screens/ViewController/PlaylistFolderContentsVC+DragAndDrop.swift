//
//  PlaylistFolderContentsVC+DragAndDrop.swift
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

/// Dragging rows to file and to reorder them.
///
/// Three things can happen to a drag that lands on this list, and which one it
/// is depends on where in a row the pointer is, not only on which row:
/// - over the middle of a **folder** row → file the dragged siblings into it
/// - near the top or bottom edge of any row → reorder at that position
/// - past the last row → bring the dragged siblings to this level
///
/// The edge bands matter: without them a folder row would swallow every drag
/// near it and folders could never be reordered relative to their neighbours,
/// which in an interleaved list means half the arrangement is unreachable.
///
/// Descending into a folder mid-drag uses UIKit's own spring loading
/// (`shouldSpringLoadRowAt`), which activates the row after a hover and lands in
/// `didSelectRowAt` — no bespoke hover timer.
extension PlaylistFolderContentsVC: UITableViewDragDelegate, UITableViewDropDelegate {
  // MARK: - Setup

  func configureDragAndDrop() {
    tableView.dragDelegate = self
    tableView.dropDelegate = self
    // On iPhone this is off by default; the whole feature depends on it.
    tableView.dragInteractionEnabled = true
  }

  /// Reordering is only meaningful when the visible order *is* the stored
  /// sibling order. Under a search or an attribute sort the row index says
  /// nothing about sortOrder, so a drop between rows would write an arbitrary
  /// position. Filing into a folder still works — that target is named.
  var allowsRowReordering: Bool {
    searchText.isEmpty && usesManualSiblingOrder
  }

  // MARK: - UITableViewDragDelegate

  func tableView(
    _ tableView: UITableView,
    itemsForBeginning session: any UIDragSession,
    at indexPath: IndexPath
  )
    -> [UIDragItem] {
    // Dragging a row that is part of the selection drags the whole selection —
    // dragging one outside it drags only that row, and does not disturb the
    // selection.
    let rowIndicesToDrag = selectionModel.selectedRowIndices.contains(indexPath.row)
      ? selectionModel.orderedSelectedRowIndices
      : [indexPath.row]
    return rowIndicesToDrag.compactMap { makeDragItem(forRowAt: $0) }
  }

  func tableView(
    _ tableView: UITableView,
    itemsForAddingTo session: any UIDragSession,
    at indexPath: IndexPath,
    point: CGPoint
  )
    -> [UIDragItem] {
    // Lets a Mac user gather rows into one drag with successive drags onto it.
    guard let dragItem = makeDragItem(forRowAt: indexPath.row) else { return [] }
    let alreadyDraggedIdentities = draggedIdentities(in: session)
    guard let identity = row(at: indexPath.row)?.identity,
          !alreadyDraggedIdentities.contains(identity)
    else { return [] }
    return [dragItem]
  }

  func tableView(_ tableView: UITableView, dragSessionWillBegin session: any UIDragSession) {
    isDraggingRows = true
  }

  func tableView(_ tableView: UITableView, dragSessionDidEnd session: any UIDragSession) {
    isDraggingRows = false
  }

  override func tableView(
    _ tableView: UITableView,
    shouldSpringLoadRowAt indexPath: IndexPath,
    with context: any UISpringLoadedInteractionContext
  )
    -> Bool {
    // Only folders are worth descending into.
    row(at: indexPath)?.asFolder != nil
  }

  private func makeDragItem(forRowAt rowIndex: Int) -> UIDragItem? {
    guard let row = row(at: rowIndex) else { return nil }
    let identity = row.identity
    // The name is what a drop outside the app receives; the identity travels as
    // the local object, which is the only form the drop handler needs.
    let itemProvider = NSItemProvider(object: row.displayName as NSString)
    let dragItem = UIDragItem(itemProvider: itemProvider)
    dragItem.localObject = identity
    return dragItem
  }

  private func draggedIdentities(in session: any UIDragSession)
    -> [PlaylistFolderBrowseRowIdentity] {
    session.items.compactMap { $0.localObject as? PlaylistFolderBrowseRowIdentity }
  }

  // MARK: - UITableViewDropDelegate

  func tableView(_ tableView: UITableView, canHandle session: any UIDropSession) -> Bool {
    // Rows only ever move within this app; a text drop from elsewhere has no
    // meaning here.
    session.localDragSession != nil
  }

  func tableView(
    _ tableView: UITableView,
    dropSessionDidUpdate session: any UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  )
    -> UITableViewDropProposal {
    guard let localDragSession = session.localDragSession else {
      return UITableViewDropProposal(operation: .cancel)
    }
    let target = resolveDropTarget(
      destinationIndexPath: destinationIndexPath,
      session: session,
      draggedIdentities: draggedIdentities(in: localDragSession)
    )
    switch target {
    case .intoFolder:
      return UITableViewDropProposal(
        operation: .move,
        intent: .insertIntoDestinationIndexPath
      )
    case .reorder:
      return UITableViewDropProposal(
        operation: .move,
        intent: .insertAtDestinationIndexPath
      )
    case .currentLevel:
      return UITableViewDropProposal(operation: .move, intent: .unspecified)
    case .rejected:
      return UITableViewDropProposal(operation: .cancel)
    }
  }

  func tableView(
    _ tableView: UITableView,
    performDropWith coordinator: any UITableViewDropCoordinator
  ) {
    let identities = coordinator.items
      .compactMap { $0.dragItem.localObject as? PlaylistFolderBrowseRowIdentity }
    guard !identities.isEmpty else { return }

    let target = resolveDropTarget(
      destinationIndexPath: coordinator.destinationIndexPath,
      session: coordinator.session,
      draggedIdentities: identities
    )
    apply(dropTarget: target, draggedIdentities: identities)
  }

  // MARK: - Resolution

  /// Turn UIKit's "which row is the pointer near" into the vocabulary
  /// `PlaylistFolderDropTargetResolver` speaks.
  private func dropProposal(
    destinationIndexPath: IndexPath?,
    session: any UIDropSession
  )
    -> PlaylistFolderDropProposal {
    guard let destinationIndexPath,
          let row = row(at: destinationIndexPath.row)
    else { return .background }

    guard row.asFolder != nil else {
      return .betweenRows(rowIndex: destinationIndexPath.row)
    }

    // Folder rows are split into three bands so they can be both a drop target
    // and something you can reorder around.
    let rowFrame = tableView.rectForRow(at: destinationIndexPath)
    let pointerY = session.location(in: tableView).y
    let edgeBandHeight = max(rowFrame.height * 0.25, 8)
    if pointerY < rowFrame.minY + edgeBandHeight {
      return .betweenRows(rowIndex: destinationIndexPath.row)
    }
    if pointerY > rowFrame.maxY - edgeBandHeight {
      return .betweenRows(rowIndex: destinationIndexPath.row + 1)
    }
    return .intoRow(rowIndex: destinationIndexPath.row)
  }

  private func resolveDropTarget(
    destinationIndexPath: IndexPath?,
    session: any UIDropSession,
    draggedIdentities: [PlaylistFolderBrowseRowIdentity]
  )
    -> PlaylistFolderDropTarget {
    PlaylistFolderDropTargetResolver.resolve(
      proposal: dropProposal(destinationIndexPath: destinationIndexPath, session: session),
      rowIdentities: displayedRowIdentities,
      draggedIdentities: draggedIdentities,
      allowsReordering: allowsRowReordering
    )
  }

  // MARK: - Applying

  private func apply(
    dropTarget: PlaylistFolderDropTarget,
    draggedIdentities: [PlaylistFolderBrowseRowIdentity]
  ) {
    let partitioned = PlaylistFolderDropTargetResolver.partition(draggedIdentities)
    let draggedFolderIds = partitioned.folderIds.compactMap { UUID(uuidString: $0) }

    switch dropTarget {
    case let .intoFolder(folderId):
      guard let destinationFolderId = UUID(uuidString: folderId) else { return }
      folderStore.moveSiblings(
        folderIds: draggedFolderIds,
        playlistIds: partitioned.playlistIds,
        from: parentFolderId,
        to: destinationFolderId
      )

    case let .reorder(targetIndex):
      reorder(draggedIdentities: draggedIdentities, toTargetIndex: targetIndex)

    case .currentLevel:
      // Everything already at this level: a no-op the store will discard,
      // which is the honest outcome of dropping rows back where they came from.
      folderStore.moveSiblings(
        folderIds: draggedFolderIds,
        playlistIds: partitioned.playlistIds,
        from: parentFolderId,
        to: parentFolderId
      )

    case .rejected:
      break
    }

    if isEditing { setEditing(false, animated: true) }
  }

  /// Reorder within the current parent. The dragged rows land consecutively,
  /// starting at the drop point adjusted for the rows lifted out above it, and
  /// keep their relative order.
  private func reorder(
    draggedIdentities: [PlaylistFolderBrowseRowIdentity],
    toTargetIndex targetIndex: Int
  ) {
    let currentRowIdentities = displayedRowIdentities
    let draggedRowIndices = draggedIdentities.compactMap { identity in
      PlaylistFolderBrowseListBuilder.rowIndex(of: identity, in: currentRowIdentities)
    }
    let insertionIndex = PlaylistFolderDropTargetResolver.adjustedInsertionIndex(
      targetRowIndex: targetIndex,
      draggedRowIndices: draggedRowIndices
    )

    folderStore.performBatchedUpdates {
      for (offset, identity) in draggedIdentities.enumerated() {
        folderStore.moveSibling(
          kind: identity.kind,
          id: identity.id,
          inFolder: parentFolderId,
          toIndex: insertionIndex + offset
        )
      }
    }
  }
}
