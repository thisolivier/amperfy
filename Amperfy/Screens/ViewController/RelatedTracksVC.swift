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
/// Presented from the song context menu's "Related Tracks" action.
class RelatedTracksVC: UITableViewController {
  private let seedSongId: String
  private let seedSongTitle: String
  private var relatedSongs: [AbstractPlayable] = []
  private var sourceInfoByIndex: [Int: String] = [:]

  init(seedSongId: String, seedSongTitle: String) {
    self.seedSongId = seedSongId
    self.seedSongTitle = seedSongTitle
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Related Tracks"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(doneTapped)
    )
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    loadRelatedTracks()
  }

  private func loadRelatedTracks() {
    let store = TrackAdjacencyStore.shared
    let context = appDelegate.storage.main.context
    let topResults = store.topRelated(for: seedSongId, limit: 20)

    var songs: [AbstractPlayable] = []
    var sourceInfoMap: [Int: String] = [:]

    for (index, result) in topResults.enumerated() {
      guard result.score.total >= TrackAdjacencyStore.minimumThreshold else { continue }
      guard let songMO = fetchSongMO(songId: result.songId, in: context) else { continue }
      let song = Song(managedObject: songMO)
      songs.append(song)

      let playlistCount = store.playlistCoOccurrenceCount(
        songIdA: seedSongId,
        songIdB: result.songId,
        in: context
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
    tableView.reloadData()
    updateContentState()
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
      emptyConfig.secondaryText =
        "Play songs from your playlists to build recommendations"
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  @objc
  private func doneTapped() {
    dismiss(animated: true)
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
    cell.display(
      playable: playable,
      playContextCb: { [weak self] tableCell in
        self?.playContext(for: tableCell)
      },
      rootView: self
    )
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
}
