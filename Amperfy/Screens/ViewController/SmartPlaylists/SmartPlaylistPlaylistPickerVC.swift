//
//  SmartPlaylistPlaylistPickerVC.swift
//  Amperfy
//
//  Playlist chooser for the smart playlist builder's membership rules
//  (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistPlaylistChoice

/// The id + display name a membership rule stores. The name is a snapshot so
/// the builder and the results summary still read correctly offline; evaluation
/// always resolves by id.
struct SmartPlaylistPlaylistChoice {
  let playlistId: String
  let name: String
}

// MARK: - SmartPlaylistPlaylistPickerVC

/// Lists the account's real, named user playlists so a membership rule can name
/// one.
///
/// The filter mirrors the engine's own definition of a "user playlist"
/// (`PlaylistMembershipQuery` / `RecentTracksQuery.songNotInAnyUserPlaylist`):
/// system playlists are excluded by the storage call, server-side smart
/// playlists by `isSmartPlaylist` (the `smart_` id prefix), and unnamed
/// playlists are dropped because a rule that renders as `Not in ""` is
/// meaningless to the user.
final class SmartPlaylistPlaylistPickerVC: UITableViewController {
  private static let cellReuseIdentifier = "SmartPlaylistPlaylistPickerCell"

  private let account: Account
  private let onPlaylistChosen: (SmartPlaylistPlaylistChoice) -> ()

  private var allPlaylists: [Playlist] = []
  private var displayedPlaylists: [Playlist] = []
  private var searchText = ""

  private lazy var playlistSearchController: UISearchController = {
    let searchController = UISearchController(searchResultsController: nil)
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = "Search Playlists"
    return searchController
  }()

  // MARK: - Init

  init(account: Account, onPlaylistChosen: @escaping (SmartPlaylistPlaylistChoice) -> ()) {
    self.account = account
    self.onPlaylistChosen = onPlaylistChosen
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Choose Playlist"
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
    navigationItem.searchController = playlistSearchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
    loadPlaylists()
  }

  // MARK: - Data

  private func loadPlaylists() {
    allPlaylists = appDelegate.storage.main.library
      .getPlaylists(for: account, areSystemPlaylistsIncluded: false)
      .filter { !$0.isSmartPlaylist && !$0.name.isEmpty }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    applySearchFilter()
  }

  private func applySearchFilter() {
    if searchText.isEmpty {
      displayedPlaylists = allPlaylists
    } else {
      displayedPlaylists = allPlaylists.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
      }
    }
    tableView.reloadData()
    updateEmptyState()
  }

  private func updateEmptyState() {
    guard displayedPlaylists.isEmpty else {
      contentUnavailableConfiguration = nil
      return
    }
    var emptyConfiguration = UIContentUnavailableConfiguration.empty()
    emptyConfiguration.text = allPlaylists.isEmpty ? "No Playlists" : "No Matching Playlists"
    emptyConfiguration.secondaryText = allPlaylists.isEmpty
      ? "Playlist rules need at least one of your own playlists."
      : nil
    contentUnavailableConfiguration = emptyConfiguration
  }

  // MARK: - UITableView

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    displayedPlaylists.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.cellReuseIdentifier,
      for: indexPath
    )
    var cellConfiguration = cell.defaultContentConfiguration()
    let playlist = displayedPlaylists[indexPath.row]
    cellConfiguration.text = playlist.name
    let songCount = playlist.songCount
    cellConfiguration.secondaryText = songCount == 1 ? "1 song" : "\(songCount) songs"
    cell.contentConfiguration = cellConfiguration
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let playlist = displayedPlaylists[indexPath.row]
    onPlaylistChosen(SmartPlaylistPlaylistChoice(playlistId: playlist.id, name: playlist.name))
    navigationController?.popViewController(animated: true)
  }
}

// MARK: UISearchResultsUpdating

extension SmartPlaylistPlaylistPickerVC: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    applySearchFilter()
  }
}
