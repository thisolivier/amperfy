//
//  PlaylistSelectorVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

// MARK: - PlaylistSelectorVC

/// Modal picker used by "Add to Playlist". Mirrors the folder-aware layout of
/// `PlaylistFolderContentsVC` (both share `PlaylistFolderBrowsingTableViewController`):
/// at the root it shows top-level folders plus unfiled playlists; tapping a
/// folder pushes a folder-scoped picker instance; tapping a playlist adds the
/// pending song(s) to it immediately (without dismissing). A bottom-corner "+"
/// creates a new playlist. The modal only closes when the user taps the close
/// button, so several playlists can be filled in one session.
class PlaylistSelectorVC: PlaylistFolderBrowsingTableViewController {
  // MARK: - Properties

  let itemsToAdd: [Song]

  private var closeButton: UIBarButtonItem!
  private var optionsButton: UIBarButtonItem!
  private var addBarButton: UIBarButtonItem!

  // MARK: - Init

  init(account: Account, itemsToAdd: [Song], parentFolderId: UUID? = nil) {
    self.itemsToAdd = itemsToAdd
    super.init(account: account, parentFolderId: parentFolderId)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    appDelegate.userStatistics.visited(.playlistSelector)
    sortType = appDelegate.storage.settings.user.playlistsSortSetting

    if let parentFolderId, let folder = folderStore.folder(byId: parentFolderId) {
      title = folder.name
    } else {
      title = itemsToAdd.count > 1
        ? "Add \(itemsToAdd.count) Songs to Playlist"
        : "Add to Playlist"
    }

    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = UITableView.automaticDimension
    tableView.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemGroupedBackground

    navigationItem.searchController = searchController
    definesPresentationContext = true

    updateNavigationItems()
    configureToolbar()

    startObservingFolderChanges()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadContent()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
      self.reloadContent()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  // MARK: - Navigation items

  private func updateNavigationItems() {
    closeButton = UIBarButtonItem.createCloseBarButton(
      target: self,
      selector: #selector(closeBarButtonPressed)
    )
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = createSortButtonMenu()
    navigationItem.rightBarButtonItems = [closeButton, optionsButton]
  }

  override func rebuildNavigationItemsForSortChange() {
    updateNavigationItems()
  }

  private func configureToolbar() {
    navigationController?.setToolbarHidden(false, animated: false)
    let flexible = UIBarButtonItem(
      barButtonSystemItem: .flexibleSpace,
      target: self,
      action: nil
    )
    addBarButton = UIBarButtonItem(
      image: .plus,
      style: .plain,
      target: self,
      action: #selector(createPlaylistBarButtonPressed)
    )
    toolbarItems = [flexible, addBarButton]
  }

  // MARK: - Browsing hooks

  override func makeChildBrowser(parentFolderId: UUID) -> UITableViewController {
    PlaylistSelectorVC(account: account, itemsToAdd: itemsToAdd, parentFolderId: parentFolderId)
  }

  override func onPlaylistSelected(_ playlist: Playlist, at indexPath: IndexPath) {
    addSongsToPlaylist(playlist, at: indexPath)
  }

  override var playlistCellShowsCacheStatus: Bool { false }

  override var playlistCellAccessoryType: UITableViewCell.AccessoryType { .none }

  // MARK: - Actions

  @objc
  private func closeBarButtonPressed(_ sender: UIBarButtonItem) {
    dismissSelf()
  }

  @objc
  private func createPlaylistBarButtonPressed(_ sender: UIBarButtonItem) {
    promptCreatePlaylist()
  }

  private func dismissSelf() {
    searchController.dismiss(animated: false, completion: nil)
    dismiss(animated: true, completion: nil)
  }

  // MARK: - Create playlist

  private func promptCreatePlaylist() {
    let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.placeholder = "Playlist name"
      textField.autocapitalizationType = .words
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
      guard let self,
            let name = alert.textFields?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { return }
      createPlaylistAndAddPendingSongs(named: name)
    })
    present(alert, animated: true)
  }

  /// Creates a playlist, adds the pending song(s) to it, files it into the
  /// current folder when the picker is folder-scoped, and keeps the modal open.
  ///
  /// Ordering is load-bearing: a freshly created playlist has an empty server
  /// id until its create request round-trips. Filing it into a folder or firing
  /// a second concurrent upload while the id is still empty caused three bugs —
  /// the playlist fell out of its folder (server never recorded the membership),
  /// a duplicate server playlist was created (two upload paths each ran
  /// `createPlaylistRemote`), and that duplicate held none of the songs. So we
  /// create-and-name the playlist on the server first (single awaited path that
  /// assigns the real id onto this same object), then push the songs, then file
  /// it into the folder using the now-assigned id.
  private func createPlaylistAndAddPendingSongs(named name: String) {
    let library = appDelegate.storage.main.library
    let playlist = library.createPlaylist(account: account)
    playlist.name = name
    appDelegate.storage.main.saveContext()

    let songs = itemsToAdd.filterSongs()
    playlist.append(playables: songs)

    guard appDelegate.storage.settings.user.isOnlineMode else {
      // Offline: no server id will be assigned, and folders are server-backed,
      // so we cannot reliably file until the playlist syncs. Reflect the local
      // add now; the folder filing happens when it is next created online.
      reloadContent()
      return
    }

    Task { @MainActor in
      do {
        let syncer = self.appDelegate.getMeta(self.account.info).librarySyncer
        // Creates the playlist on the server and reconciles the assigned id
        // onto this same object (via `validatePlaylistId`) before anything is
        // keyed on the id.
        try await syncer.syncUpload(playlistToUpdateName: playlist)
        try await syncer.syncUpload(playlistToAddSongs: playlist, songs: songs)
        // The playlist now carries its real server id — safe to file it.
        if let parentFolderId = self.parentFolderId {
          self.folderStore.addPlaylists([playlist.id], to: parentFolderId)
        }
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Create", error: error)
      }
      self.reloadContent()
    }
  }

  // MARK: - Adding songs

  /// Uploads the given playables to the playlist and appends them locally.
  /// When `showConfirmationAt` is provided, a transient checkmark is flashed on
  /// that row so the user gets non-blocking feedback that the add succeeded.
  private func addPendingSongs(
    to playlist: Playlist,
    playables: [AbstractPlayable],
    showConfirmationAt indexPath: IndexPath?
  ) {
    let songs = playables.filterSongs()
    guard !songs.isEmpty else { return }

    playlist.append(playables: songs)
    if let indexPath {
      flashAddedConfirmation(at: indexPath)
    }

    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer.syncUpload(
        playlistToAddSongs: playlist,
        songs: songs
      )
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Add Songs", error: error)
    }}
  }

  private func flashAddedConfirmation(at indexPath: IndexPath) {
    guard let cell = tableView.cellForRow(at: indexPath) else { return }
    let checkmark = UIImageView(image: .check)
    checkmark.tintColor = appDelegate.storage.settings.accounts
      .getSetting(account.info).read.themePreference.asColor
    cell.accessoryView = checkmark
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak cell] in
      cell?.accessoryView = nil
    }
  }

  /// Single-tap add: adds the pending song(s) to the tapped playlist and shows
  /// an inline confirmation. When some songs are already present the user is
  /// asked how to handle the duplicates. The modal stays open in every case.
  private func addSongsToPlaylist(_ playlist: Playlist, at indexPath: IndexPath) {
    let itemsNotContained = playlist.notContaines(playables: itemsToAdd)
    if itemsNotContained.count != itemsToAdd.count {
      let alert = UIAlertController(
        title: nil,
        message: "Some Songs are already in this Playlist.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Add Duplicates", style: .default) { [weak self] _ in
        self?.addPendingSongs(
          to: playlist,
          playables: self?.itemsToAdd ?? [],
          showConfirmationAt: indexPath
        )
      })
      alert.addAction(UIAlertAction(title: "Skip Duplicates", style: .default) { [weak self] _ in
        self?.addPendingSongs(
          to: playlist,
          playables: Array(itemsNotContained),
          showConfirmationAt: indexPath
        )
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      present(alert, animated: true)
    } else {
      addPendingSongs(to: playlist, playables: itemsToAdd, showConfirmationAt: indexPath)
    }
  }
}
