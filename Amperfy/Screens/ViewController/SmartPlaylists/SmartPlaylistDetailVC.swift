//
//  SmartPlaylistDetailVC.swift
//  Amperfy
//
//  Results screen for the on-device Smart Playlists feature (V1 spec, 2026-08-17).
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
import CoreData
import UIKit

/// The FROZEN smart playlist result, played like any other list.
///
/// The single most important behaviour here is what this screen does *not* do:
/// it never evaluates the query. On appear it rehydrates the stored song ids
/// through `SmartPlaylistStore.resolveSongs`, which preserves the order the
/// last refresh produced and silently drops songs that have since vanished.
/// The list only ever changes when the user taps Refresh (or runs a new query
/// from the builder) — that is the product promise, so there is deliberately no
/// pull-to-refresh and no `viewIsAppearing` re-evaluation.
final class SmartPlaylistDetailVC: MultiSourceTableViewController {
  private static let playContextName = "Smart Playlist"
  private static let emptyStateCellReuseIdentifier = "SmartPlaylistEmptyStateCell"

  // MARK: - State

  private let smartPlaylistStore = SmartPlaylistStore.shared

  private var displayedSongs: [Song] = []
  private var currentQuery = SmartPlaylistQuery()
  private var lastRefreshedAt: Date?
  private var wasLastRefreshOffline = false
  private var songsMissingAddedDateCount = 0
  /// Caveats known only from a refresh outcome; they survive frozen reloads
  /// because they describe the query that produced the current result, and that
  /// query cannot change without going through the builder.
  private var hasIncompletePlaylistData = false
  private var droppedPlaylistRules: [SmartPlaylistRule] = []

  private var isRefreshInProgress = false
  private var currentRefreshStatusText: String?
  /// First-use gate: the builder is thrown up over the empty screen exactly
  /// once, so cancelling it does not immediately re-present it.
  private var hasPresentedInitialBuilder = false

  private let headerView = SmartPlaylistDetailHeaderView()

  // MARK: - Init

  init(account: Account) {
    super.init(style: .plain, account: account)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Smart Playlists"

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(
      UITableViewCell.self,
      forCellReuseIdentifier: Self.emptyStateCellReuseIdentifier
    )
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0

    configureHeaderView()

    containableAtIndexPathCallback = { [weak self] indexPath in
      self?.displayedSongs.element(at: indexPath.row)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      self?.makePlayContext(startIndex: indexPath.row)
    }
    swipeCallback = { [weak self] indexPath, completion in
      guard let self, let song = displayedSongs.element(at: indexPath.row) else {
        completion(nil); return
      }
      completion(SwipeActionContext(
        containable: song,
        playContext: makePlayContext(startIndex: indexPath.row)
      ))
    }

    loadFrozenState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    // Rehydrating (NOT re-evaluating) keeps the list honest about songs that
    // were deleted while the user was elsewhere, without changing membership.
    if !isRefreshInProgress {
      loadFrozenState()
    }
    presentBuilderOnFirstUseIfNeeded()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    resizeTableHeaderViewToFit()
  }

  // MARK: - Header

  private func configureHeaderView() {
    headerView.onRefreshTapped = { [weak self] in self?.runRefresh() }
    headerView.onPlayTapped = { [weak self] in self?.playAll(isShuffled: false) }
    headerView.onShuffleTapped = { [weak self] in self?.playAll(isShuffled: true) }
    headerView.onEditQueryTapped = { [weak self] in self?.presentBuilder() }
    tableView.tableHeaderView = headerView
  }

  /// A table header view is frame-driven, so its Auto Layout content has to be
  /// measured by hand and the frame re-stamped whenever the text reflows.
  private func resizeTableHeaderViewToFit() {
    guard let tableHeaderView = tableView.tableHeaderView else { return }
    let availableWidth = tableView.bounds.width
    guard availableWidth > 0 else { return }
    tableHeaderView.frame.size.width = availableWidth
    let fittingSize = tableHeaderView.systemLayoutSizeFitting(
      CGSize(width: availableWidth, height: 0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    guard abs(tableHeaderView.frame.height - fittingSize.height) > 0.5 else { return }
    tableHeaderView.frame.size.height = fittingSize.height
    tableView.tableHeaderView = tableHeaderView
  }

  private func refreshHeaderView() {
    headerView.configure(with: SmartPlaylistHeaderConfiguration(
      querySummaryText: currentQuery.summaryText,
      artworkSong: displayedSongs.first,
      themePreference: appDelegate.storage.settings.accounts.getSetting(account.info).read
        .themePreference,
      refreshedAt: lastRefreshedAt,
      wasOfflineRefresh: wasLastRefreshOffline,
      isRefreshInProgress: isRefreshInProgress,
      refreshStatusText: currentRefreshStatusText,
      noteText: composedNoteText(),
      songCount: displayedSongs.count
    ))
    // Attachment depends on the same state the header just rendered (first use
    // versus a stored query, refresh in flight or not), so it is decided here
    // rather than only on a full reload — a refresh started from the first-use
    // screen has to swap the overlay for the live progress header immediately.
    updateEmptyState()
    resizeTableHeaderViewToFit()
  }

  /// The caveat footer. Every note here exists because the honest answer is
  /// "this result may not be what you assume" — see the engine README.
  private func composedNoteText() -> String? {
    // "No songs match this query" is stated by the stand-in row, not repeated
    // here.
    var notes = [String]()
    if songsMissingAddedDateCount > 0 {
      let songWord = songsMissingAddedDateCount == 1 ? "song has" : "songs have"
      notes.append("\(songsMissingAddedDateCount) \(songWord) no added-date yet")
    }
    if hasIncompletePlaylistData {
      notes.append("Playlist data may be incomplete")
    }
    for droppedRule in droppedPlaylistRules {
      notes.append("Rule skipped — playlist no longer exists: \(droppedRule.displayText)")
    }
    return notes.isEmpty ? nil : notes.joined(separator: "\n")
  }

  // MARK: - Frozen state

  private func loadFrozenState() {
    guard let storedState = smartPlaylistStore.loadCurrentState() else {
      currentQuery = SmartPlaylistQuery()
      displayedSongs = []
      lastRefreshedAt = nil
      wasLastRefreshOffline = false
      songsMissingAddedDateCount = 0
      applyLoadedData()
      return
    }
    currentQuery = storedState.query
    lastRefreshedAt = storedState.refreshedAt
    wasLastRefreshOffline = storedState.wasOfflineRefresh
    songsMissingAddedDateCount = storedState.songsMissingAddedDate
    let songManagedObjects = smartPlaylistStore.resolveSongs(
      for: storedState,
      context: appDelegate.storage.main.context,
      account: account
    )
    displayedSongs = songManagedObjects.map { Song(managedObject: $0) }
    applyLoadedData()
  }

  private func applyLoadedData() {
    tableView.reloadData()
    refreshHeaderView()
  }

  /// What stands in for the song list while it is empty.
  ///
  /// Both cases are REAL ROWS rather than a `contentUnavailableConfiguration`
  /// overlay, and that is an accessibility decision as much as a visual one
  /// (BUG-1 + BUG-3, QA 2026-08-17, both confirmed on device):
  ///
  ///  * A `UITableView` with zero rows publishes itself as a bare "Empty list"
  ///    and stops vending everything else it contains — the table header's
  ///    Refresh / Play / Shuffle / Edit Query buttons vanished from the
  ///    accessibility tree while staying on screen and tappable. Setting
  ///    `accessibilityElements` or `isAccessibilityElement` does not override
  ///    it: this is a `UITableViewController`, so `view` IS the table view and
  ///    the table implements the container callbacks itself. One real row is
  ///    what the table responds to.
  ///  * The overlay went further: while it was up, the navigation bar stopped
  ///    publishing its own back button and title too, and the overlay's "Build
  ///    Query" button — being a subview of the empty table — was never vended,
  ///    so the whole first-use screen was unreachable. It also drew straight
  ///    through the table header (BUG-1), because it centres over the entire
  ///    table rather than below the header.
  private enum EmptyStateRow {
    /// Nothing has ever been built. Tapping the row opens the builder.
    case firstUse
    /// A stored query ran and matched nothing.
    case noMatches
  }

  private var emptyStateRow: EmptyStateRow? {
    guard displayedSongs.isEmpty else { return nil }
    if smartPlaylistStore.hasStoredState { return .noMatches }
    // Mid-first-refresh there is no query yet AND nothing to explain — the
    // header's own progress line is the feedback.
    return isRefreshInProgress ? nil : .firstUse
  }

  /// Attaches or detaches the header to match the state it just rendered.
  ///
  /// First use detaches it entirely: every action it offers is meaningless
  /// before a query exists, and leaving it attached was exactly what BUG-1 saw
  /// drawn through the empty state. The very first refresh brings it straight
  /// back, because its progress line is the feedback for that tap.
  private func updateEmptyState() {
    // Never used on this screen — see `EmptyStateRow`. Cleared defensively so a
    // future edit cannot reintroduce the overlay by accident.
    contentUnavailableConfiguration = nil
    guard emptyStateRow == .firstUse else {
      if tableView.tableHeaderView !== headerView {
        tableView.tableHeaderView = headerView
        resizeTableHeaderViewToFit()
      }
      return
    }
    tableView.tableHeaderView = nil
  }

  // MARK: - Refresh

  /// The one and only path that changes the list. Never pops UI on failure —
  /// `SmartPlaylistRefresher` reports sync errors through the event logger and
  /// degrades to the local cache, which beats failing an explicit user tap.
  private func runRefresh() {
    guard !isRefreshInProgress else { return }
    isRefreshInProgress = true
    currentRefreshStatusText = SmartPlaylistRefreshPhase.evaluating.displayText
    refreshHeaderView()

    let refresher = SmartPlaylistRefresher(
      storage: appDelegate.storage.main,
      librarySyncer: appDelegate.getMeta(account.info).librarySyncer,
      account: account,
      eventLogger: appDelegate.eventLogger
    )
    let isOnline = appDelegate.storage.settings.user.isOnlineMode &&
      appDelegate.networkMonitor.isConnectedToNetwork
    let queryToRun = currentQuery

    Task { @MainActor in
      let outcome = await refresher.refresh(
        query: queryToRun,
        isOnline: isOnline,
        progress: { [weak self] phase in
          guard let self else { return }
          currentRefreshStatusText = phase.displayText
          refreshHeaderView()
        }
      )
      apply(refreshOutcome: outcome)
    }
  }

  private func apply(refreshOutcome outcome: SmartPlaylistRefreshOutcome) {
    isRefreshInProgress = false
    currentRefreshStatusText = nil
    currentQuery = outcome.state.query
    lastRefreshedAt = outcome.state.refreshedAt
    wasLastRefreshOffline = outcome.wasOfflineRefresh
    songsMissingAddedDateCount = outcome.state.songsMissingAddedDate
    hasIncompletePlaylistData = outcome.hasIncompletePlaylistData
    droppedPlaylistRules = outcome.droppedPlaylistRules
    displayedSongs = outcome.songs.map { Song(managedObject: $0) }
    applyLoadedData()
  }

  // MARK: - Builder

  private func presentBuilderOnFirstUseIfNeeded() {
    guard !smartPlaylistStore.hasStoredState, !hasPresentedInitialBuilder else { return }
    hasPresentedInitialBuilder = true
    presentBuilder()
  }

  private func presentBuilder() {
    // Opening the builder by hand also satisfies the first-use presentation, so
    // dismissing it can never bounce straight back into it.
    hasPresentedInitialBuilder = true
    let builderVC = SmartPlaylistBuilderVC(
      account: account,
      initialQuery: currentQuery,
      onRunQuery: { [weak self] editedQuery in
        guard let self else { return }
        currentQuery = editedQuery
        runRefresh()
      }
    )
    let builderNavigationController = UINavigationController(rootViewController: builderVC)
    present(builderNavigationController, animated: true)
  }

  // MARK: - Playback

  private func makePlayContext(startIndex: Int) -> PlayContext {
    PlayContext(name: Self.playContextName, index: startIndex, playables: displayedSongs)
  }

  private func playAll(isShuffled: Bool) {
    guard !displayedSongs.isEmpty else { return }
    let playContext = makePlayContext(startIndex: 0)
    if isShuffled {
      appDelegate.player.playShuffled(context: playContext)
    } else {
      appDelegate.player.play(context: playContext)
    }
  }

  // MARK: - UITableView

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    emptyStateRow != nil ? 1 : displayedSongs.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    if let emptyStateRow {
      return makeEmptyStateCell(for: tableView, at: indexPath, kind: emptyStateRow)
    }
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    if let song = displayedSongs.element(at: indexPath.row) {
      cell.display(
        playable: song,
        playContextCb: { [weak self] cellArgument in
          guard let self,
                let tappedPlayable = (cellArgument as? PlayableTableCell)?.playable
          else { return nil }
          // Resolve by the cell's bound song identity, not its row: a refresh
          // wholesale-replaces `displayedSongs`, so an index captured before
          // the swap can point at a different song afterwards.
          return RecentTracksPlaybackResolver.resolvePlayContext(
            tappedSongId: tappedPlayable.id,
            name: Self.playContextName,
            currentSongs: displayedSongs
          )
        },
        rootView: self
      )
    }
    return cell
  }

  /// The stand-in row for an empty list. First use is a tappable invitation
  /// into the builder; "no matches" is a statement, so it is inert.
  private func makeEmptyStateCell(
    for tableView: UITableView,
    at indexPath: IndexPath,
    kind: EmptyStateRow
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.emptyStateCellReuseIdentifier,
      for: indexPath
    )
    var contentConfiguration = UIListContentConfiguration.subtitleCell()
    switch kind {
    case .firstUse:
      contentConfiguration.image = UIImage(systemName: "wand.and.stars")
      contentConfiguration.text = "No Smart Playlist Yet"
      contentConfiguration.secondaryText =
        "Tap to build a query — added date, play history, playlist membership. The matching songs are frozen here until you refresh."
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .noMatches:
      contentConfiguration.text = "No songs match this query"
      contentConfiguration.secondaryText =
        "Refresh again after your library changes, or tap Edit Query to loosen the rules."
      contentConfiguration.textProperties.color = .secondaryLabel
      cell.accessoryType = .none
      cell.selectionStyle = .none
    }
    contentConfiguration.secondaryTextProperties.color = .secondaryLabel
    contentConfiguration.secondaryTextProperties.numberOfLines = 0
    cell.contentConfiguration = contentConfiguration
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    emptyStateRow != nil ? UITableView.automaticDimension : PlayableTableCell.rowHeight
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    PlayableTableCell.rowHeight
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if let emptyStateRow {
      if emptyStateRow == .firstUse { presentBuilder() }
      return
    }
    guard let tappedCell = tableView.cellForRow(at: indexPath) as? PlayableTableCell,
          let tappedPlayable = tappedCell.playable,
          let playContext = RecentTracksPlaybackResolver.resolvePlayContext(
            tappedSongId: tappedPlayable.id,
            name: Self.playContextName,
            currentSongs: displayedSongs
          )
    else { return }
    appDelegate.player.play(context: playContext)
  }
}
