//
//  Playlist+ItemsSyncState.swift
//  AmperfyKit
//
//  Created for AMP-19 — items-sync state moved onto the playlist row.
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

import Foundation

/// Whether this playlist's items (`PlaylistItemMO`) have been fetched via the
/// per-playlist API call. The bulk `getPlaylists` endpoint only returns
/// playlist metadata — items are only populated when each playlist is
/// individually fetched.
///
/// This state used to live in a UserDefaults-backed tracker
/// (`PlaylistItemsSyncTracker`), keyed globally by playlist id. That survived
/// every store wipe the resync screen didn't own — account cleanup, manual
/// store deletion — and the stale "synced" claims starved `PlaylistSyncWorker`
/// while "Show in Playlists" asserted confident, wrong emptiness. On the row,
/// the state is account-scoped for free and dies with the data: a wiped or
/// cleaned store simply has no rows left to lie about.
///
/// The staleness signal is a CHANGE in the server-advertised song count
/// (`remoteSongCount`, captured cheaply during the bulk list sync) versus the
/// count recorded when the items were last synced — NOT a mismatch between
/// `remoteSongCount` and the number of local items. The server's count includes
/// podcast / directory / unavailable entries that Amperfy skips when building
/// the local `items` relationship, so for playlists holding such entries a
/// local/remote gap is PERMANENT and comparing against it would re-invalidate
/// on every pass forever (the "Show in Playlists" blocking-sync storm).
/// Comparing remote-now to remote-at-last-sync never churns on the permanent
/// gap, while a genuine server edit (which moves the count) still triggers a
/// single re-sync.
extension Playlist {
  /// `true` once the items relationship reflects a landed per-playlist fetch.
  public var isItemsSynced: Bool {
    managedObject.isItemsSynced
  }

  /// The remote count recorded at the last successful items sync, or `nil`
  /// when no baseline was recorded (stored as `-1` on the row).
  private var itemsSyncedRemoteCountBaseline: Int? {
    managedObject.itemsSyncedRemoteCount >= 0
      ? Int(managedObject.itemsSyncedRemoteCount)
      : nil
  }

  /// Marks the items synced and records the current server-advertised count as
  /// the baseline a later reconcile compares against.
  public func markItemsSynced(remoteSongCount: Int) {
    let baseline = Int64(remoteSongCount)
    guard !managedObject.isItemsSynced
      || managedObject.itemsSyncedRemoteCount != baseline else { return }
    managedObject.isItemsSynced = true
    managedObject.itemsSyncedRemoteCount = baseline
    library.saveContext()
  }

  /// Marks the items synced only when there is evidence the fetch actually
  /// landed. Returns `true` if the playlist was marked.
  ///
  /// The syncers open `syncDown(playlist:)` with `guard isSyncAllowed else
  /// { return }`, so a connectivity blip or a flip into offline mode makes the
  /// call succeed while fetching nothing at all. Marking unconditionally after
  /// that records a lie: a playlist that was never fetched shows no remote
  /// count CHANGE for the reconcile to catch. Evidence is either local items
  /// present, or a server that genuinely advertises an empty playlist
  /// (nothing to fetch, so nothing to prove).
  @discardableResult
  public func markItemsSyncedIfFetchLanded() -> Bool {
    guard localItemCount > 0 || remoteSongCount == 0 else { return false }
    markItemsSynced(remoteSongCount: remoteSongCount)
    return true
  }

  /// Clears the synced flag (and baseline) so the items are re-fetched on next
  /// access.
  public func invalidateItemsSync() {
    guard managedObject.isItemsSynced || managedObject.itemsSyncedRemoteCount >= 0
    else { return }
    managedObject.isItemsSynced = false
    managedObject.itemsSyncedRemoteCount = -1
    library.saveContext()
  }

  /// `true` when the server-advertised count has CHANGED since the items were
  /// last synced — i.e. the playlist was edited on the server and the local
  /// items are stale.
  ///
  /// A current remote count of `0` is treated as unknown/unavailable (the bulk
  /// list sync may not have populated it yet) and never signals an edit. With
  /// no recorded baseline there is no evidence of an edit either — inventing
  /// one from the local item count would reintroduce the
  /// podcast/unavailable-gap churn described above.
  public var hasServerSideItemsEdit: Bool {
    guard remoteSongCount > 0 else { return false }
    guard let itemsSyncedRemoteCountBaseline else { return false }
    return remoteSongCount != itemsSyncedRemoteCountBaseline
  }

  /// Reconciles the synced flag against the current server-advertised count
  /// and clears it when the server edited the playlist since the last items
  /// sync. No-op when already unsynced or when no edit is detectable. Returns
  /// `true` if the playlist was invalidated (i.e. it now needs a re-sync).
  @discardableResult
  public func reconcileItemsSyncState() -> Bool {
    guard managedObject.isItemsSynced else { return false }
    guard hasServerSideItemsEdit else { return false }
    invalidateItemsSync()
    return true
  }
}
