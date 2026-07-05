//
//  RelatedTracksVC.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 12 — Track Adjacency Engine, Phase 2).
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

/// Shows top 20 related tracks for a given song, ranked by adjacency score.
/// Pushed from the song context menu's "Related Tracks" action (a page with
/// deep onward traversals, so never presented modally).
class RelatedTracksVC: UITableViewController {
  private let seedSongId: String
  private let seedSongTitle: String
  private weak var originRootView: UIViewController?
  private var relatedSongs: [AbstractPlayable] = []
  private var sourceInfoByIndex: [Int: String] = [:]
  /// Nav-bar large-title state as it was before this screen appeared, restored on disappear so
  /// screens beneath/above on the shared stack are unaffected (user-specced build-60 feedback).
  private var priorPrefersLargeTitles: Bool?

  init(seedSongId: String, seedSongTitle: String, originRootView: UIViewController) {
    self.seedSongId = seedSongId
    self.seedSongTitle = seedSongTitle
    self.originRootView = originRootView
    // `.grouped`, matching PlaylistDetailVC exactly (its `super.init(style: .grouped, ...)`) —
    // `.insetGrouped` gave these rows extra side padding vs regular playlist views (build-60
    // user feedback).
    super.init(style: .grouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Related Tracks To:"
    navigationItem.largeTitleDisplayMode = .always
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    setupToolbar()
    showLoadingState()
    Task { @MainActor in
      await loadRelatedTracks()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Standard collapsing large title for this VC only — capture the bar's prior
    // preference and restore it on disappear.
    if let navigationBar = navigationController?.navigationBar {
      priorPrefersLargeTitles = navigationBar.prefersLargeTitles
      navigationBar.prefersLargeTitles = true
    }
    if !relatedSongs.isEmpty {
      navigationController?.setToolbarHidden(false, animated: animated)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Pushed onto a shared stack: never leave our toolbar behind for the
    // screens beneath (or above) us.
    navigationController?.setToolbarHidden(true, animated: animated)
    if let priorPrefersLargeTitles {
      navigationController?.navigationBar.prefersLargeTitles = priorPrefersLargeTitles
    }
  }

  private func showLoadingState() {
    var loadingConfig = UIContentUnavailableConfiguration.loading()
    loadingConfig.text = "Finding related tracks\u{2026}"
    contentUnavailableConfiguration = loadingConfig
  }

  private func loadRelatedTracks() async {
    let service = DefaultTrackAdjacencyService.shared
    let seedSongId = seedSongId
    let context = appDelegate.storage.main.context

    let topResults = service.topRelated(for: seedSongId, limit: 20)

    var songs: [AbstractPlayable] = []
    var sourceInfoMap: [Int: String] = [:]

    for result in topResults {
      guard result.score.total >= TrackAdjacencyWeights.minimumThreshold else { continue }
      guard let songMO = fetchSongMO(songId: result.songId, in: context) else { continue }
      let song = Song(managedObject: songMO)
      songs.append(song)

      let playlistCount = service.playlistCoOccurrenceCount(
        songIdA: seedSongId,
        songIdB: result.songId
      )
      if playlistCount > 0 {
        let playlistWord = playlistCount == 1 ? "playlist" : "playlists"
        sourceInfoMap[songs.count - 1] = "In \(playlistCount) \(playlistWord) nearby"
      } else if result.score.album > 0 {
        sourceInfoMap[songs.count - 1] = "Same album"
      }
    }

    relatedSongs = songs
    sourceInfoByIndex = sourceInfoMap
    if let seedSongMO = fetchSongMO(songId: seedSongId, in: context) {
      installSeedHeader(seedSong: Song(managedObject: seedSongMO))
    }
    tableView.reloadData()
    updateContentState()
    updateToolbarState()
  }

  /// Seed-badge header (restyled per build-60 user feedback): the "Related
  /// Tracks To:" text now lives in the nav bar's large title, so the header is
  /// just the seed track as a rounded badge — transparent fill, theme-accent
  /// border — the standard row UI minus its options (…) control,
  /// non-interactive.
  private func installSeedHeader(seedSong: Song) {
    let container = UIView()

    let badge = UIView()
    badge.backgroundColor = .clear
    badge.layer.cornerRadius = 12
    badge.layer.borderWidth = 1.5
    badge.layer.borderColor = view.tintColor.cgColor
    badge.layer.masksToBounds = true
    badge.translatesAutoresizingMaskIntoConstraints = false

    guard let seedCell = UINib(nibName: PlayableTableCell.typeName, bundle: nil)
      .instantiate(withOwner: nil).first as? PlayableTableCell else { return }
    seedCell.display(playable: seedSong, playContextCb: nil, rootView: self)
    seedCell.optionsButton.isHidden = true
    seedCell.isUserInteractionEnabled = false
    seedCell.backgroundColor = .clear
    seedCell.translatesAutoresizingMaskIntoConstraints = false

    badge.addSubview(seedCell)
    container.addSubview(badge)

    NSLayoutConstraint.activate([
      badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      badge.heightAnchor.constraint(equalToConstant: PlayableTableCell.rowHeight),
      seedCell.topAnchor.constraint(equalTo: badge.topAnchor),
      seedCell.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
      seedCell.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
      seedCell.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
    ])

    let headerHeight = 8 + PlayableTableCell.rowHeight + 8
    container.frame = CGRect(
      x: 0, y: 0,
      width: tableView.bounds.width,
      height: headerHeight
    )
    tableView.tableHeaderView = container
  }

  private func fetchSongMO(
    songId: String,
    in context: NSManagedObjectContext
  )
    -> SongMO? {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(SongMO.id), songId)
    fetchRequest.fetchLimit = 1
    return try? context.fetch(fetchRequest).first
  }

  private func updateContentState() {
    if relatedSongs.isEmpty {
      var emptyConfig = UIContentUnavailableConfiguration.empty()
      emptyConfig.text = "No related tracks found"
      if DefaultTrackAdjacencyService.shared.isStale {
        emptyConfig.secondaryText = "Building recommendations\u{2026} check back shortly"
      } else {
        emptyConfig.secondaryText =
          "Songs that appear together in your playlists will show up here"
      }
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - Play context

  private func playContext(for cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return PlayContext(
      name: "Related to \(seedSongTitle)",
      index: indexPath.row,
      playables: relatedSongs
    )
  }

  // MARK: - Table data source

  override func tableView(
    _ tableView: UITableView,
    numberOfRowsInSection section: Int
  )
    -> Int {
    relatedSongs.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: PlayableTableCell.typeName,
      for: indexPath
    ) as! PlayableTableCell
    let playable = relatedSongs[indexPath.row]
    // Pass originRootView so EntityPreviewActionBuilder navigates
    // on the main nav stack (not the modal's nav stack).
    // Falls back to self if origin deallocated.
    let navigationRoot = originRootView ?? self
    cell.display(
      playable: playable,
      playContextCb: { [weak self] tableCell in
        self?.playContext(for: tableCell)
      },
      rootView: navigationRoot
    )
    // Append source info to artist subtitle
    if let sourceInfo = sourceInfoByIndex[indexPath.row] {
      let artistName = playable.creatorName
      cell.artistLabel.text = "\(artistName) \(CommonString.oneMiddleDot) \(sourceInfo)"
    }
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    didSelectRowAt indexPath: IndexPath
  ) {
    tableView.deselectRow(at: indexPath, animated: true)
    let playContext = PlayContext(
      name: "Related to \(seedSongTitle)",
      index: indexPath.row,
      playables: relatedSongs
    )
    appDelegate.player.play(context: playContext)
  }

  // MARK: - Toolbar actions

  private func setupToolbar() {
    let playButton = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      style: .plain,
      target: self,
      action: #selector(playAllTapped)
    )
    playButton.tintColor = .systemGreen

    let shuffleButton = UIBarButtonItem(
      image: UIImage(systemName: "shuffle"),
      style: .plain,
      target: self,
      action: #selector(shuffleTapped)
    )

    let queueButton = UIBarButtonItem(
      image: UIImage(systemName: "text.badge.plus"),
      style: .plain,
      target: self,
      action: #selector(queueMenuTapped(_:))
    )

    let flexSpace = UIBarButtonItem(
      barButtonSystemItem: .flexibleSpace,
      target: nil,
      action: nil
    )

    toolbarItems = [playButton, flexSpace, shuffleButton, flexSpace, queueButton]
  }

  private func updateToolbarState() {
    let hasItems = !relatedSongs.isEmpty
    toolbarItems?.forEach { item in
      if item.style != .plain { return } // skip flex spacers
      item.isEnabled = hasItems
    }
    navigationController?.setToolbarHidden(false, animated: false)
  }

  private var filteredTracks: [AbstractPlayable] {
    relatedSongs.filterCached(
      dependigOn: appDelegate.storage.settings.user.isOfflineMode
    )
  }

  @objc
  private func playAllTapped() {
    guard !relatedSongs.isEmpty else { return }
    Haptics.success.vibrate(
      isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
    )
    let playContext = PlayContext(
      name: "Related to \(seedSongTitle)",
      playables: filteredTracks
    )
    appDelegate.player.play(context: playContext)
  }

  @objc
  private func shuffleTapped() {
    guard !relatedSongs.isEmpty else { return }
    Haptics.success.vibrate(
      isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
    )
    let playContext = PlayContext(
      name: "Related to \(seedSongTitle)",
      playables: filteredTracks
    )
    appDelegate.player.playShuffled(context: playContext)
  }

  @objc
  private func queueMenuTapped(_ sender: UIBarButtonItem) {
    let alert = UIAlertController(
      title: "Add to Queue",
      message: "\(filteredTracks.count) tracks",
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Insert to User Queue", style: .default) { [weak self] _ in
      guard let self else { return }
      Haptics.success.vibrate(
        isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
      )
      appDelegate.player.insertUserQueue(playables: filteredTracks)
    })
    alert.addAction(UIAlertAction(title: "Append to User Queue", style: .default) { [weak self] _ in
      guard let self else { return }
      Haptics.success.vibrate(
        isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
      )
      appDelegate.player.appendUserQueue(playables: filteredTracks)
    })
    alert
      .addAction(UIAlertAction(title: "Insert to Context Queue", style: .default) { [weak self] _ in
        guard let self else { return }
        Haptics.success.vibrate(
          isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
        )
        appDelegate.player.insertContextQueue(playables: filteredTracks)
      })
    alert
      .addAction(UIAlertAction(title: "Append to Context Queue", style: .default) { [weak self] _ in
        guard let self else { return }
        Haptics.success.vibrate(
          isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled
        )
        appDelegate.player.appendContextQueue(playables: filteredTracks)
      })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.popoverPresentationController?.barButtonItem = sender
    present(alert, animated: true)
  }
}
