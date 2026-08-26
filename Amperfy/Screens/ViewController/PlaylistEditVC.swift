//
//  PlaylistEditVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 06.12.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import CoreData
import UIKit

// MARK: - PlaylistEditMode

enum PlaylistEditMode {
  case reorder
  case delete
}

// MARK: - PlaylistEditVC

class PlaylistEditVC: SingleSnapshotFetchedResultsTableViewController<PlaylistItemMO> {
  override var sceneTitle: String? { playlist.name }

  private var fetchedResultsController: PlaylistItemsFetchedResultsController!

  let playlist: Playlist
  var onDoneCB: VoidFunctionCallback?
  /// row to pre-scroll to on first layout, mirroring the presenting list's position
  var initialScrollRowIndex: Int?

  private var doneButton: UIBarButtonItem!
  private var selectBarButton: UIBarButtonItem!
  private var deleteBarButton: UIBarButtonItem!
  private var addBarButton: UIBarButtonItem!
  private var moveUpBarButton: UIBarButtonItem!
  private var moveDownBarButton: UIBarButtonItem!

  var detailOperationsView: GenericDetailTableHeader?

  private var selectedItems = [PlaylistItem]()
  private var editMode = PlaylistEditMode.reorder
  private var isOrderSyncUploadPending = false
  private var orderSyncUploadDebounceWorkItem: DispatchWorkItem?

  init(account: Account, playlist: Playlist) {
    self.playlist = playlist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistDetailDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistItemMO = object as? PlaylistItemMO
        else {
          return UITableViewCell()
        }
        let playlistItem = PlaylistItem(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistItemMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlistItem: playlistItem)
      }
    source.playlist = playlist
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    fetchedResultsController = PlaylistItemsFetchedResultsController(
      forPlaylist: playlist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: playlist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: nil
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)

    tableView.allowsSelection = true
    tableView.allowsMultipleSelection = true
    tableView.allowsSelectionDuringEditing = true
    tableView.dragDelegate = self
    tableView.dropDelegate = self
    tableView.dragInteractionEnabled = true
    detailOperationsView?.startEditing()

    navigationController?.setToolbarHidden(false, animated: false)
    selectBarButton = UIBarButtonItem(
      title: "Select",
      style: .plain,
      target: self,
      action: #selector(selectBarButtonPressed)
    )
    deleteBarButton = UIBarButtonItem(
      image: .trash,
      style: .plain,
      target: self,
      action: #selector(deleteBarButtonPressed)
    )
    addBarButton = UIBarButtonItem(
      image: .plus,
      style: .plain,
      target: self,
      action: #selector(addBarButtonPressed)
    )
    moveUpBarButton = UIBarButtonItem(
      image: .chevronUp,
      style: .plain,
      target: self,
      action: #selector(moveUpBarButtonPressed)
    )
    moveUpBarButton.accessibilityLabel = "Move Up"
    moveDownBarButton = UIBarButtonItem(
      image: .chevronDown,
      style: .plain,
      target: self,
      action: #selector(moveDownBarButtonPressed)
    )
    moveDownBarButton.accessibilityLabel = "Move Down"

    changeEditMode(.reorder)
    refreshBarButtons()
  }

  func changeEditMode(_ newMode: PlaylistEditMode) {
    editMode = newMode
    (diffableDataSource as? PlaylistDetailDiffableDataSource)?
      .isMoveAllowed = (editMode == .reorder)
    (diffableDataSource as? PlaylistDetailDiffableDataSource)?.isEditAllowed = true
    selectedItems.removeAll()
    tableView.reloadData()
    refreshToolbar()
  }

  private func refreshToolbar() {
    let flexible = UIBarButtonItem(
      barButtonSystemItem: UIBarButtonItem.SystemItem.flexibleSpace,
      target: nil,
      action: nil
    )
    switch editMode {
    case .reorder:
      selectBarButton.title = "Select"
      setToolbarItems([selectBarButton, flexible, addBarButton], animated: false)
    case .delete:
      selectBarButton.title = "Single"
      deleteBarButton.isEnabled = !selectedItems.isEmpty
      if selectedItems.isEmpty {
        setToolbarItems(
          [selectBarButton, flexible, addBarButton, flexible, deleteBarButton],
          animated: false
        )
      } else {
        refreshMoveButtonsEnabledState()
        setToolbarItems(
          [
            selectBarButton,
            flexible,
            moveUpBarButton,
            UIBarButtonItem.fixedSpace(16),
            moveDownBarButton,
            flexible,
            deleteBarButton,
          ],
          animated: false
        )
      }
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrollToInitialRowIfNeeded()
  }

  /// One-shot: runs on the first layout pass in which the rows exist, so the
  /// modal appears already scrolled instead of visibly jumping.
  private func scrollToInitialRowIfNeeded() {
    guard let rowIndex = initialScrollRowIndex,
          tableView.numberOfSections > 0 else { return }
    let rowCount = tableView.numberOfRows(inSection: 0)
    guard rowCount > 0 else { return }
    initialScrollRowIndex = nil
    tableView.scrollToRow(
      at: IndexPath(row: min(rowIndex, rowCount - 1), section: 0),
      at: .top,
      animated: false
    )
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    detailOperationsView?.endEditing()
    Task { @MainActor in
      await self.flushPendingOrderSyncUpload()
    }
    onDoneCB?()
  }

  @IBAction
  func doneBarButtonPressed(_ sender: UIBarButtonItem) {
    dismiss()
  }

  @IBAction
  func selectBarButtonPressed(_ sender: Any) {
    changeEditMode((editMode == .reorder) ? .delete : .reorder)
  }

  @IBAction
  func deleteBarButtonPressed(_ sender: Any) {
    let selectedItemsSorted = selectedItems.sorted(by: { $0.order > $1.order })

    Task { @MainActor in
      // the server delete API is index based: bring the server order up to date first
      await self.flushPendingOrderSyncUpload()
      do {
        for item in selectedItemsSorted {
          guard let index = self.playlist.getFirstIndex(item: item) else { continue }
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .syncUpload(
              playlistToDeleteSong: self.playlist,
              index: index
            )
          self.playlist.remove(at: index)
        }
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Entry Remove", error: error)
      }
      self.detailOperationsView?.refresh()
    }

    selectedItems.removeAll()
    // clear the stale checkmark state of the still-visible cells
    tableView.reloadData()
    refreshToolbar()
  }

  @IBAction
  func moveUpBarButtonPressed(_ sender: Any) {
    moveSelectedItems(upwards: true)
  }

  @IBAction
  func moveDownBarButtonPressed(_ sender: Any) {
    moveSelectedItems(upwards: false)
  }

  /// Moves every selected item one step up or down. A non-contiguous selection moves as
  /// independent contiguous runs: each run shifts by one and runs merge once they touch,
  /// mirroring desktop list editors with move buttons (a nudge translates, it never gathers).
  private func moveSelectedItems(upwards: Bool) {
    guard editMode == .delete, !selectedItems.isEmpty,
          let dataSource = diffableDataSource else { return }
    var snapshot = dataSource.snapshot()
    let orderedItemIds = snapshot.itemIdentifiers
    let selectedItemIds = Set(selectedItems.map { $0.objectID })
    let selectedIndices = orderedItemIds.enumerated()
      .filter { selectedItemIds.contains($0.element) }
      .map(\.offset)

    // Playlist.movePlaylistItem is only index-consistent for upward moves
    // (fromIndex > toIndex): for downward moves the ordered relationship and the
    // sparse `order` attribute disagree by one row. Both nudge directions are
    // therefore expressed purely as upward moves.
    var modelMoves = [(fromIndex: Int, toIndex: Int)]()
    for run in contiguousRuns(ofSortedIndices: selectedIndices) {
      if upwards {
        guard run.first > 0 else { continue }
        // every item of the run swaps with the unselected neighbor above it
        let neighborItemId = orderedItemIds[run.first - 1]
        snapshot.deleteItems([neighborItemId])
        snapshot.insertItems([neighborItemId], afterItem: orderedItemIds[run.last])
        for index in run.first ... run.last {
          modelMoves.append((fromIndex: index, toIndex: index - 1))
        }
      } else {
        guard run.last < orderedItemIds.count - 1 else { continue }
        // the unselected neighbor below the run moves up to just above it
        let neighborItemId = orderedItemIds[run.last + 1]
        snapshot.deleteItems([neighborItemId])
        snapshot.insertItems([neighborItemId], beforeItem: orderedItemIds[run.first])
        modelMoves.append((fromIndex: run.last + 1, toIndex: run.first))
      }
    }
    guard !modelMoves.isEmpty else { return }

    // Apply the animated snapshot first; the fetched results controller update that
    // follows the model change applies without animation (see
    // SingleSnapshotFetchedResultsTableViewController) and must find this state already.
    dataSource.apply(snapshot, animatingDifferences: true)
    dataSource.exectueAfterAnimation {
      for modelMove in modelMoves {
        self.playlist.movePlaylistItem(fromIndex: modelMove.fromIndex, to: modelMove.toIndex)
      }
      self.scheduleOrderSyncUpload()
    }
    refreshToolbar()
  }

  private func contiguousRuns(ofSortedIndices sortedIndices: [Int])
    -> [(first: Int, last: Int)] {
    var runs = [(first: Int, last: Int)]()
    for index in sortedIndices {
      if let lastRun = runs.last, index == lastRun.last + 1 {
        runs[runs.count - 1].last = index
      } else {
        runs.append((first: index, last: index))
      }
    }
    return runs
  }

  private func refreshMoveButtonsEnabledState() {
    guard let dataSource = diffableDataSource else { return }
    let orderedItemIds = dataSource.snapshot().itemIdentifiers
    let selectedItemIds = Set(selectedItems.map { $0.objectID })
    let selectedIndices = orderedItemIds.enumerated()
      .filter { selectedItemIds.contains($0.element) }
      .map(\.offset)
    let totalCount = orderedItemIds.count
    let selectedCount = selectedIndices.count
    // Disabled only when the selection is packed against that end of the list
    moveUpBarButton.isEnabled = selectedIndices.enumerated()
      .contains { $0.element > $0.offset }
    moveDownBarButton.isEnabled = selectedIndices.enumerated()
      .contains { $0.element < totalCount - selectedCount + $0.offset }
  }

  private func scheduleOrderSyncUpload() {
    isOrderSyncUploadPending = true
    orderSyncUploadDebounceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        await self.flushPendingOrderSyncUpload()
      }
    }
    orderSyncUploadDebounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func flushPendingOrderSyncUpload() async {
    guard isOrderSyncUploadPending else { return }
    isOrderSyncUploadPending = false
    orderSyncUploadDebounceWorkItem?.cancel()
    orderSyncUploadDebounceWorkItem = nil
    guard appDelegate.storage.settings.user.isOnlineMode, playlist.songCount > 0 else { return }
    do {
      try await appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistToUpdateOrder: playlist)
    } catch {
      appDelegate.eventLogger.report(topic: "Playlist Upload Order Update", error: error)
    }
  }

  @IBAction
  func addBarButtonPressed(_ sender: Any) {
    let playlistAddVC = PlaylistAddLibraryVC(account: account)
    playlistAddVC.addToPlaylistManager.playlist = playlist
    playlistAddVC.addToPlaylistManager.onDoneCB = {
      self.detailOperationsView?.refresh()
      self.tableView.reloadData()
    }
    let playlistAddNav = UINavigationController(rootViewController: playlistAddVC)
    present(playlistAddNav, animated: true, completion: nil)
  }

  private func dismiss() {
    dismiss(animated: true, completion: nil)
  }

  func refreshBarButtons() {
    doneButton = UIBarButtonItem(
      title: "Done",
      style: .plain,
      target: self,
      action: #selector(doneBarButtonPressed)
    )
    refreshToolbar()

    navigationItem.leftItemsSupplementBackButton = true
    navigationItem.rightBarButtonItem = doneButton
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlistItem: PlaylistItem
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = tableView.dequeueCell(for: tableView, at: indexPath)
    if let song = playlistItem.playable.asSong {
      cell.display(
        playable: song,
        displayMode: (editMode == .reorder) ? .reorder : .selection,
        playContextCb: nil,
        rootView: self,
        isMarked: (selectedItems.firstIndex { $0 == playlistItem } != nil)
      )
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard editMode == .delete else { return }

    let item = fetchedResultsController.getWrappedEntity(at: indexPath)
    if let cell = tableView.cellForRow(at: indexPath) as? PlayableTableCell {
      let markedIndex = selectedItems.firstIndex { $0 == item }
      if let markedIndex = markedIndex {
        selectedItems.remove(at: markedIndex)
        cell.isMarked = false
      } else {
        selectedItems.append(item)
        cell.isMarked = true
      }
      cell.refresh()
    }
    refreshToolbar()
  }
}

// MARK: UITableViewDragDelegate

extension PlaylistEditVC: UITableViewDragDelegate {
  func tableView(
    _ tableView: UITableView,
    itemsForBeginning session: UIDragSession,
    at indexPath: IndexPath
  )
    -> [UIDragItem] {
    // Create empty DragItem -> we are using tableView(_:moveRowAt:to:) method
    [UIDragItem]()
  }

  func tableView(
    _ tableView: UITableView,
    dragPreviewParametersForRowAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters? {
    let parameter = UIDragPreviewParameters()
    parameter.backgroundColor = .clear
    return parameter
  }
}

// MARK: UITableViewDropDelegate

extension PlaylistEditVC: UITableViewDropDelegate {
  func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
    false
  }

  func tableView(
    _ tableView: UITableView,
    performDropWith coordinator: UITableViewDropCoordinator
  ) {
    // Local drags with one item go through the existing tableView(_:moveRowAt:to:) method on the data source
  }

  func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {}

  func tableView(
    _ tableView: UITableView,
    dropPreviewParametersForRowAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters? {
    let parameter = UIDragPreviewParameters()
    return parameter
  }
}
