//
//  RecentTracksDetailVC.swift
//  Amperfy
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

import AmperfyKit
import CoreData
import UIKit

/// Synthetic playlist detail view for the "Recently Added Tracks" home widget.
///
/// Two display modes (persisted in `UserDefaults`):
///
/// * **Top N**  — most recent N qualifying songs (default N=14, range 5–50).
/// * **Last M days** — all qualifying songs added in the last M days
///   (default M=7, range 1–60).
///
/// "Qualifying" means the song's parent album is not a whole album under
/// `WholeAlbumPredicates` with `minSongCount = 5` (stricter than the
/// library-wide threshold of 3 — false positives are more annoying in this
/// list than false negatives are in the Albums filter; see BACKLOG.md §3.2).
///
/// Tapping a row plays the synthetic queue starting at the tapped index.
/// There is no FRC backing this view; it is a pure-fetch snapshot that
/// re-runs on `viewIsAppearing` and on every mode/value change.
final class RecentTracksDetailVC: MultiSourceTableViewController {
  // MARK: - Mode

  enum Mode: Int {
    case topN = 0
    case lastMDays = 1
  }

  // MARK: - UserDefaults keys

  private enum DefaultsKey {
    static let mode = "recentTracksDetailMode"
    static let topN = "recentTracksDetailTopN"
    static let lastMDays = "recentTracksDetailLastMDays"
  }

  /// Persistence for the fork-only triage filter. Lives in AmperfyKit (
  /// `amperfy.fork.*` namespace) so it is unit-tested in isolation; the
  /// pre-existing mode/count keys above predate that convention and stay
  /// inline to preserve users' stored values.
  private let filterSettings = RecentTracksFilterSettings()

  // MARK: - Defaults / bounds

  private static let defaultTopN = 14
  private static let minTopN = 5
  private static let maxTopN = 50

  private static let defaultLastMDays = 7
  private static let minLastMDays = 1
  private static let maxLastMDays = 60

  // MARK: - State

  private var songs: [Song] = []

  private var mode: Mode {
    get {
      Mode(rawValue: UserDefaults.standard.integer(forKey: DefaultsKey.mode)) ?? .topN
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.mode)
    }
  }

  private var topNValue: Int {
    get {
      let stored = UserDefaults.standard.integer(forKey: DefaultsKey.topN)
      return stored == 0 ? Self.defaultTopN : stored
    }
    set {
      UserDefaults.standard.set(newValue, forKey: DefaultsKey.topN)
    }
  }

  private var lastMDaysValue: Int {
    get {
      let stored = UserDefaults.standard.integer(forKey: DefaultsKey.lastMDays)
      return stored == 0 ? Self.defaultLastMDays : stored
    }
    set {
      UserDefaults.standard.set(newValue, forKey: DefaultsKey.lastMDays)
    }
  }

  /// When on, the list hides tracks the user has already filed into at least
  /// one real user playlist (Recently Added acts as a triage inbox). Persisted
  /// in the `amperfy.fork.*` namespace; defaults to off, so upgrading users see
  /// the unchanged, unfiltered list until they opt in. See
  /// `RecentTracksQuery.songNotInAnyUserPlaylist`.
  private var hideSongsInPlaylists: Bool {
    get { filterSettings.hideSongsInPlaylists }
    set { filterSettings.hideSongsInPlaylists = newValue }
  }

  // MARK: - Header subviews

  private let modeControl = UISegmentedControl(items: ["Top N", "Last M days"])
  private let stepperLabel = UILabel()
  private let stepper = UIStepper()
  /// Subtle caption shown in the section header ONLY while the "hide filed
  /// tracks" filter is active: "Filtered · N unfiled" (N = current visible
  /// count, live-updating). Hidden entirely when the filter is off. No toast.
  private let filterCaptionLabel = UILabel()
  private var cachedHeaderView: UIView?

  // MARK: - Filter bar button

  private var optionsButton: UIBarButtonItem!

  // MARK: - Bulk select

  /// Id-keyed selection model for Edit mode (survives live `refreshSongs()`
  /// reloads; see `RecentTracksSelection`).
  private let selection = RecentTracksSelection()

  /// Floating action bar shown while in Edit mode, mirroring
  /// `PlaylistFolderContentsVC`'s convention: a count label plus filled
  /// action buttons anchored above the mini-player safe area.
  private let editActionBar = UIView()
  private var addToPlaylistButton: UIButton!
  private var selectAllButton: UIButton!
  private var selectionCountLabel: UILabel!
  private static let editActionBarHeight: CGFloat = 68

  // MARK: - Init

  init(account: Account) {
    super.init(style: .plain, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Recently Added Tracks"

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    updateOptionsMenu()
    navigationItem.rightBarButtonItem = optionsButton

    // Bulk-select support: multi-select checkmarks appear only in Edit mode.
    tableView.allowsMultipleSelectionDuringEditing = true
    configureEditActionBar()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionHeaderHeight = UITableView.automaticDimension
    tableView.estimatedSectionHeaderHeight = 88
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif
    refreshControl?.addTarget(
      self,
      action: #selector(handleRefresh),
      for: .valueChanged
    )

    modeControl.translatesAutoresizingMaskIntoConstraints = false
    modeControl.selectedSegmentIndex = mode.rawValue
    modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

    stepperLabel.translatesAutoresizingMaskIntoConstraints = false
    stepperLabel.font = .preferredFont(forTextStyle: .body)
    stepperLabel.textColor = .label

    stepper.translatesAutoresizingMaskIntoConstraints = false
    stepper.addTarget(self, action: #selector(stepperChanged), for: .valueChanged)

    filterCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
    filterCaptionLabel.font = .preferredFont(forTextStyle: .caption1)
    filterCaptionLabel.textColor = .secondaryLabel
    filterCaptionLabel.isHidden = true

    syncStepperToCurrentMode()

    containableAtIndexPathCallback = { [weak self] indexPath in
      self?.songs.element(at: indexPath.row)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      self?.makePlayContext(startIndex: indexPath.row)
    }
    swipeCallback = { [weak self] indexPath, completion in
      guard let self, let song = songs.element(at: indexPath.row) else {
        completion(nil); return
      }
      let playContext = makePlayContext(startIndex: indexPath.row)
      completion(SwipeActionContext(containable: song, playContext: playContext))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    refreshSongs()
  }

  @objc
  private func handleRefresh() {
    refreshSongs()
    refreshControl?.endRefreshing()
  }

  // MARK: - Data refresh

  private func refreshSongs() {
    let context = appDelegate.storage.main.context
    let songMOs: [SongMO]
    switch mode {
    case .topN:
      songMOs = RecentTracksQuery.topN(
        context: context,
        n: topNValue,
        hideSongsInPlaylists: hideSongsInPlaylists,
        account: account
      )
    case .lastMDays:
      songMOs = RecentTracksQuery.lastMDays(
        context: context,
        m: lastMDaysValue,
        hideSongsInPlaylists: hideSongsInPlaylists,
        account: account
      )
    }
    songs = songMOs.map { Song(managedObject: $0) }
    updateFilterCaption()
    tableView.reloadData()
    // A wholesale reload drops UIKit's selection state. Reconcile the id-keyed
    // model against the new visible list (a just-filed track hidden by the
    // filter must fall out of the selection) then re-apply checkmarks for any
    // still-visible selected rows so Edit mode survives a live refresh.
    if isEditing {
      selection.retainOnly(visibleSongs: songs)
      for (row, song) in songs.enumerated() where selection.isSelected(songId: song.id) {
        tableView.selectRow(
          at: IndexPath(row: row, section: 0),
          animated: false,
          scrollPosition: .none
        )
      }
      updateEditActionBarState()
    }
    if songs.isEmpty {
      var emptyConfig = UIContentUnavailableConfiguration.empty()
      if hideSongsInPlaylists {
        emptyConfig.text = "Nothing left to file"
        emptyConfig.secondaryText =
          "Every recently added single or EP is already in a playlist. Turn off the filter to see them all."
      } else {
        emptyConfig.text = "No recently added singles or EPs"
        emptyConfig.secondaryText = "Tracks from albums with fewer than 5 songs will appear here"
      }
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  /// Updates the section-header filter caption. Shows "Filtered · N unfiled"
  /// (N = current visible count) ONLY while the "hide filed tracks" filter is
  /// on; hides it (empty text, zero height) when off. Caption only — no toast.
  /// Safe to call before the header is built (the label exists from init).
  private func updateFilterCaption() {
    if let caption = RecentTracksFilterCaption.text(
      hideSongsInPlaylists: hideSongsInPlaylists,
      visibleCount: songs.count
    ) {
      filterCaptionLabel.text = caption
      filterCaptionLabel.isHidden = false
    } else {
      filterCaptionLabel.text = ""
      filterCaptionLabel.isHidden = true
    }
  }

  // MARK: - Mode / stepper handlers

  @objc
  private func modeChanged() {
    mode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .topN
    syncStepperToCurrentMode()
    refreshSongs()
  }

  @objc
  private func stepperChanged() {
    let newValue = Int(stepper.value)
    switch mode {
    case .topN:
      topNValue = newValue
    case .lastMDays:
      lastMDaysValue = newValue
    }
    updateStepperLabel()
    refreshSongs()
  }

  private func syncStepperToCurrentMode() {
    switch mode {
    case .topN:
      stepper.minimumValue = Double(Self.minTopN)
      stepper.maximumValue = Double(Self.maxTopN)
      stepper.stepValue = 1
      stepper.value = Double(topNValue)
    case .lastMDays:
      stepper.minimumValue = Double(Self.minLastMDays)
      stepper.maximumValue = Double(Self.maxLastMDays)
      stepper.stepValue = 1
      stepper.value = Double(lastMDaysValue)
    }
    updateStepperLabel()
  }

  private func updateStepperLabel() {
    switch mode {
    case .topN:
      stepperLabel.text = "Top \(topNValue)"
    case .lastMDays:
      let days = lastMDaysValue
      stepperLabel.text = "Last \(days) day\(days == 1 ? "" : "s")"
    }
  }

  // MARK: - Filter menu

  /// Installs the options menu. It is a `lazyMenu` so the "Select Tracks" /
  /// "Done" row and the filter toggle's checkmark are rebuilt from the current
  /// state on every open — following the `PlaylistFolderContentsVC` +
  /// `createOptionsBarButton` convention used by the fork's list screens.
  private func updateOptionsMenu() {
    optionsButton.menu = UIMenu.lazyMenu { [weak self] in
      guard let self else { return [] }

      let toggleFiled = UIAction(
        title: "Hide tracks already in playlists",
        image: UIImage(systemName: "text.badge.minus"),
        state: hideSongsInPlaylists ? .on : .off,
        handler: { [weak self] _ in
          guard let self else { return }
          hideSongsInPlaylists.toggle()
          refreshSongs()
        }
      )
      let filterMenu = UIMenu(
        title: "Filter",
        options: .displayInline,
        children: [toggleFiled]
      )

      let selectTracks = UIAction(
        title: isEditing ? "Done" : "Select Tracks",
        image: UIImage(systemName: "checkmark.circle"),
        handler: { [weak self] _ in
          guard let self else { return }
          setEditing(!isEditing, animated: true)
        }
      )
      let selectMenu = UIMenu(options: .displayInline, children: [selectTracks])

      return [selectMenu, filterMenu]
    }
  }

  // MARK: - Bulk select: action bar

  /// Builds the floating "Add to Playlist" action bar shown in Edit mode,
  /// mirroring `PlaylistFolderContentsVC.configureEditActionBar`.
  private func configureEditActionBar() {
    editActionBar.translatesAutoresizingMaskIntoConstraints = false
    editActionBar.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground
    editActionBar.isHidden = true
    view.addSubview(editActionBar)

    let separator = UIView()
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.backgroundColor = .separator
    editActionBar.addSubview(separator)

    let countLabel = UILabel()
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .preferredFont(forTextStyle: .caption1)
    countLabel.textColor = ThemeStore.shared.dynamicSecondaryText ?? .secondaryLabel
    countLabel.textAlignment = .center
    countLabel.text = "0 selected"
    editActionBar.addSubview(countLabel)
    selectionCountLabel = countLabel

    // Leading "Select All" / "Deselect All" toggle on the count row. Borderless
    // so it reads as a secondary control next to the count and the primary
    // filled "Add to Playlist…" button below.
    var selectAllConfig = UIButton.Configuration.plain()
    selectAllConfig.title = "Select All"
    selectAllConfig.buttonSize = .small
    selectAllConfig.contentInsets = .zero
    let selectAllToggle = UIButton(configuration: selectAllConfig)
    selectAllToggle.translatesAutoresizingMaskIntoConstraints = false
    selectAllToggle.addTarget(
      self,
      action: #selector(toggleSelectAll),
      for: .touchUpInside
    )
    editActionBar.addSubview(selectAllToggle)
    selectAllButton = selectAllToggle

    var config = UIButton.Configuration.filled()
    config.title = "Add to Playlist…"
    config.image = UIImage(systemName: "text.badge.plus")
    config.imagePadding = 8
    config.cornerStyle = .medium
    config.buttonSize = .medium
    let addButton = UIButton(configuration: config)
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addButton.addTarget(self, action: #selector(addSelectedToPlaylist), for: .touchUpInside)
    addButton.isEnabled = false
    editActionBar.addSubview(addButton)
    addToPlaylistButton = addButton

    NSLayoutConstraint.activate([
      editActionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editActionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editActionBar.heightAnchor.constraint(equalToConstant: Self.editActionBarHeight),
      editActionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      separator.topAnchor.constraint(equalTo: editActionBar.topAnchor),
      separator.leadingAnchor.constraint(equalTo: editActionBar.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: editActionBar.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 0.5),

      countLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
      countLabel.centerXAnchor.constraint(equalTo: editActionBar.centerXAnchor),

      selectAllToggle.leadingAnchor.constraint(
        equalTo: editActionBar.leadingAnchor,
        constant: 16
      ),
      selectAllToggle.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),

      addButton.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
      addButton.leadingAnchor.constraint(equalTo: editActionBar.leadingAnchor, constant: 16),
      addButton.trailingAnchor.constraint(equalTo: editActionBar.trailingAnchor, constant: -16),
      addButton.bottomAnchor.constraint(equalTo: editActionBar.bottomAnchor, constant: -8),
    ])
  }

  private func updateEditActionBarState() {
    let count = selection.count
    addToPlaylistButton.isEnabled = count > 0
    selectionCountLabel.text = count == 1 ? "1 selected" : "\(count) selected"

    // Select All ⇄ Deselect All toggle: flip the label based on whether every
    // VISIBLE (filtered) row is already ticked. Disabled when the list is empty
    // (nothing to select). Standard batch-edit pattern.
    let allSelected = selection.areAllSelected(in: songs)
    selectAllButton.isEnabled = !songs.isEmpty
    selectAllButton.configuration?.title = allSelected ? "Deselect All" : "Select All"
  }

  /// Select All / Deselect All handler for the edit bar. Toggles between the two
  /// based on current state: if every visible row is already selected, this
  /// clears the selection; otherwise it selects the whole VISIBLE (filtered)
  /// list. With the "hide filed tracks" filter on, the visible list is exactly
  /// the unfiled backlog, so one tap selects the entire inbox. Keeps the id-keyed
  /// model and the UIKit table checkmarks in sync.
  @objc
  private func toggleSelectAll() {
    if selection.areAllSelected(in: songs) {
      selection.clear()
      for row in songs.indices {
        tableView.deselectRow(at: IndexPath(row: row, section: 0), animated: false)
      }
    } else {
      selection.selectAll(visibleSongs: songs)
      for row in songs.indices {
        tableView.selectRow(
          at: IndexPath(row: row, section: 0),
          animated: false,
          scrollPosition: .none
        )
      }
    }
    updateEditActionBarState()
  }

  // MARK: - Bulk select: edit mode

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    if !editing {
      selection.clear()
    }
    // Already-visible cells: flip selectionStyle so the multi-select checkmarks
    // can render (UIKit skips them on `.none`); restore `.none` on exit to keep
    // the tap-to-play cells unhighlighted. Newly dequeued cells are covered in
    // cellForRowAt.
    for case let playableCell as PlayableTableCell in tableView.visibleCells {
      playableCell.selectionStyle = editing ? .default : .none
    }
    editActionBar.isHidden = !editing
    tableView.contentInset.bottom = editing ? Self.editActionBarHeight : 0
    // The options menu's "Select Tracks"/"Done" label depends on isEditing;
    // it is a lazyMenu so it rebuilds on next open, no explicit reinstall
    // needed here.
    updateEditActionBarState()
  }

  /// Collects the selected songs (in list order) and reuses the app-wide
  /// playlist picker (`PlaylistSelectorVC`) to add them — the same flow the
  /// add-to-playlist swipe action, context menu, and player use. The picker
  /// performs the server upload + local append itself (see
  /// `PlaylistSongAdder`, which centralises that ordering and is unit-tested).
  /// After presenting we leave Edit mode; when the user returns, the list
  /// re-runs its fetch on `viewIsAppearing`, so with the "hide filed tracks"
  /// filter on the just-added tracks disappear live — the inbox completing
  /// itself.
  @objc
  private func addSelectedToPlaylist() {
    let selectedSongs = selection.selectedSongs(from: songs)
    guard !selectedSongs.isEmpty else { return }
    let selectPlaylistVC = AppStoryboard.Main.segueToPlaylistSelector(
      account: account,
      itemsToAdd: selectedSongs
    )
    let selectPlaylistNav = UINavigationController(rootViewController: selectPlaylistVC)
    present(selectPlaylistNav, animated: true)
    setEditing(false, animated: true)
  }

  // MARK: - PlayContext helper

  private func makePlayContext(startIndex: Int) -> PlayContext {
    PlayContext(
      name: "Recently Added Tracks",
      index: startIndex,
      playables: songs
    )
  }

  // MARK: - UITableView

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    songs.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    // UIKit only renders the Edit-mode multi-select checkmark when the cell's
    // selectionStyle is not `.none` (which PlayableTableCell hardcodes for its
    // tap-to-play look). Covers cells configured while Edit mode is active;
    // setEditing(_:animated:) below handles the already-visible ones.
    cell.selectionStyle = isEditing ? .default : .none
    if let song = songs.element(at: indexPath.row) {
      cell.display(
        playable: song,
        playContextCb: { [weak self] cellArg in
          guard let self,
                let tappedPlayable = (cellArg as? PlayableTableCell)?.playable
          else { return nil }
          // Resolve by the cell's originally-bound song identity, not by its
          // current table position: `songs` may have been wholesale-replaced
          // by a `refreshSongs()` reload that raced this tap, so re-deriving
          // an index here and indexing into the (possibly new) `songs` array
          // can silently resolve to the wrong song. See
          // `RecentTracksPlaybackResolver` for details.
          return RecentTracksPlaybackResolver.resolvePlayContext(
            tappedSongId: tappedPlayable.id,
            name: "Recently Added Tracks",
            currentSongs: songs
          )
        },
        rootView: self
      )
    }
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    PlayableTableCell.rowHeight
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    PlayableTableCell.rowHeight
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    // In Edit mode a tap ticks/unticks the row for bulk actions instead of
    // playing. Keep the row visibly selected (checkmark) and update the bar.
    if isEditing {
      if let song = songs.element(at: indexPath.row) {
        selection.select(songId: song.id)
      }
      updateEditActionBarState()
      return
    }

    tableView.deselectRow(at: indexPath, animated: true)
    // Resolve by the tapped CELL's currently-bound song identity, not by
    // `indexPath.row` indexing into `songs` directly: `songs` may have been
    // wholesale-replaced by a `refreshSongs()` reload that raced this tap.
    // `cellForRow(at:)` reflects whatever `reloadData()` last configured
    // that visible cell with, which is the correct, consistent value to
    // resolve against here. See `RecentTracksPlaybackResolver` for details.
    guard let tappedCell = tableView.cellForRow(at: indexPath) as? PlayableTableCell,
          let tappedPlayable = tappedCell.playable,
          let playContext = RecentTracksPlaybackResolver.resolvePlayContext(
            tappedSongId: tappedPlayable.id,
            name: "Recently Added Tracks",
            currentSongs: songs
          )
    else { return }
    appDelegate.player.play(context: playContext)
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    guard isEditing else { return }
    if let song = songs.element(at: indexPath.row) {
      selection.deselect(songId: song.id)
    }
    updateEditActionBarState()
  }

  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    if let cached = cachedHeaderView { return cached }

    let headerView = UIView()
    // PR 17.2: when a gradient is active for this style, keep the header
    // transparent so the gradient shows through. Otherwise retain the
    // solid `.backgroundColor` so the filter header stays readable.
    let style = traitCollection.userInterfaceStyle
    headerView.backgroundColor = ThemeStore.shared.resolvedGradient(for: style) != nil
      ? .clear
      : .backgroundColor

    headerView.addSubview(modeControl)
    headerView.addSubview(stepperLabel)
    headerView.addSubview(stepper)
    headerView.addSubview(filterCaptionLabel)

    NSLayoutConstraint.activate([
      modeControl.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      modeControl.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
      modeControl.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),

      stepperLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      stepperLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),

      stepper.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
      stepper.centerYAnchor.constraint(equalTo: stepperLabel.centerYAnchor),
      stepper.leadingAnchor.constraint(
        greaterThanOrEqualTo: stepperLabel.trailingAnchor,
        constant: 12
      ),

      // Caption sits under the stepper row and defines the header's bottom.
      // When the filter is off it is hidden with empty text (zero height), so
      // the small top spacing is the only residual — negligible, and the header
      // uses automaticDimension so it re-measures either way.
      filterCaptionLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      filterCaptionLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: headerView.trailingAnchor,
        constant: -16
      ),
      filterCaptionLabel.topAnchor.constraint(equalTo: stepperLabel.bottomAnchor, constant: 8),
      filterCaptionLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),
    ])

    cachedHeaderView = headerView
    updateFilterCaption()
    return headerView
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    UITableView.automaticDimension
  }
}
