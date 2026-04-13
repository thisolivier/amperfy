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

  // MARK: - Header subviews

  private let modeControl = UISegmentedControl(items: ["Top N", "Last M days"])
  private let stepperLabel = UILabel()
  private let stepper = UIStepper()
  private var cachedHeaderView: UIView?

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

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionHeaderHeight = UITableView.automaticDimension
    tableView.estimatedSectionHeaderHeight = 88
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    modeControl.translatesAutoresizingMaskIntoConstraints = false
    modeControl.selectedSegmentIndex = mode.rawValue
    modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

    stepperLabel.translatesAutoresizingMaskIntoConstraints = false
    stepperLabel.font = .preferredFont(forTextStyle: .body)
    stepperLabel.textColor = .label

    stepper.translatesAutoresizingMaskIntoConstraints = false
    stepper.addTarget(self, action: #selector(stepperChanged), for: .valueChanged)

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

  // MARK: - Data refresh

  private func refreshSongs() {
    let context = appDelegate.storage.main.context
    let songMOs: [SongMO]
    switch mode {
    case .topN:
      songMOs = RecentTracksQuery.topN(context: context, n: topNValue)
    case .lastMDays:
      songMOs = RecentTracksQuery.lastMDays(context: context, m: lastMDaysValue)
    }
    songs = songMOs.map { Song(managedObject: $0) }
    tableView.reloadData()
    if songs.isEmpty {
      var emptyConfig = UIContentUnavailableConfiguration.empty()
      emptyConfig.text = "No recently added singles or EPs"
      emptyConfig.secondaryText = "Tracks from albums with fewer than 5 songs will appear here"
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
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
    if let song = songs.element(at: indexPath.row) {
      cell.display(
        playable: song,
        playContextCb: { [weak self] cellArg in
          guard let self,
                let path = self.tableView.indexPath(for: cellArg)
          else { return nil }
          return makePlayContext(startIndex: path.row)
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
    tableView.deselectRow(at: indexPath, animated: true)
    appDelegate.player.play(context: makePlayContext(startIndex: indexPath.row))
  }

  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    if let cached = cachedHeaderView { return cached }

    let headerView = UIView()
    headerView.backgroundColor = .backgroundColor

    headerView.addSubview(modeControl)
    headerView.addSubview(stepperLabel)
    headerView.addSubview(stepper)

    NSLayoutConstraint.activate([
      modeControl.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      modeControl.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
      modeControl.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),

      stepperLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      stepperLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
      stepperLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),

      stepper.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
      stepper.centerYAnchor.constraint(equalTo: stepperLabel.centerYAnchor),
      stepper.leadingAnchor.constraint(
        greaterThanOrEqualTo: stepperLabel.trailingAnchor,
        constant: 12
      ),
    ])

    cachedHeaderView = headerView
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
