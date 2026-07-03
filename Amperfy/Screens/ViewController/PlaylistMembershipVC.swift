//
//  PlaylistMembershipVC.swift
//  Amperfy
//
//  Created by the Amperfy spike (Feature C — Show playlists).
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

/// Bare table showing which user playlists contain a given song.
/// Pushed from the song `...` menu's "Show in Playlists" action.
/// Tapping a row pushes that playlist's detail; popping back returns here.
class PlaylistMembershipVC: UITableViewController {
  private var playlists: [Playlist]
  private let onSelect: (Playlist) -> ()
  private var isLoading: Bool

  init(playlists: [Playlist], isLoading: Bool = false, onSelect: @escaping (Playlist) -> ()) {
    self.playlists = playlists
    self.isLoading = isLoading
    self.onSelect = onSelect
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Show in Playlists"
    tableView.register(
      UINib(nibName: PlaylistTableCell.typeName, bundle: nil),
      forCellReuseIdentifier: PlaylistTableCell.typeName
    )
    tableView.rowHeight = PlaylistTableCell.rowHeight
    updateContentState()
  }

  func updateWithPlaylists(_ playlists: [Playlist]) {
    self.playlists = playlists
    isLoading = false
    tableView.reloadData()
    updateContentState()
  }

  private func updateContentState() {
    if isLoading {
      var loadingConfig = UIContentUnavailableConfiguration.loading()
      loadingConfig.text = "Syncing playlists\u{2026}"
      contentUnavailableConfiguration = loadingConfig
    } else if playlists.isEmpty {
      var emptyConfig = UIContentUnavailableConfiguration.empty()
      emptyConfig.text = "This song isn't in any playlists"
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - Table data source

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    playlists.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: PlaylistTableCell.typeName,
      for: indexPath
    ) as! PlaylistTableCell
    cell.display(playlist: playlists[indexPath.row], rootView: self)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let playlist = playlists[indexPath.row]
    // Pushed screen: the detail lands on top, so popping back returns here —
    // the traversal the push style exists for.
    onSelect(playlist)
  }
}
