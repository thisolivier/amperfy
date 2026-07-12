//
//  RecentTracksSelection.swift
//  AmperfyKit
//
//  Created for the Recently Added bulk-select feature.
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

/// View-model backing the Recently Added detail screen's bulk-select ("Edit")
/// mode. Tracks which songs the user has ticked, keyed by stable song `id`
/// rather than table index, so a live `refreshSongs()` reload (e.g. the triage
/// filter removing just-filed tracks) cannot silently re-point a selection at
/// the wrong row.
///
/// The house convention elsewhere (`PlaylistFolderContentsVC`) reads
/// `tableView.indexPathsForSelectedRows` directly, which is fine for a static
/// list but is not unit-testable and breaks when the backing array is
/// wholesale-replaced mid-selection — exactly what happens here once the
/// "hide filed tracks" filter and bulk-add work together (adding tracks to a
/// playlist makes them vanish from a filtered list). Pulling the selection out
/// into this id-keyed model keeps the two features consistent and testable.
///
/// This type is UIKit-free on purpose so it can be unit-tested in AmperfyKit.
public final class RecentTracksSelection {
  /// Ids of the currently-selected songs. A `Set` so membership checks and
  /// toggles are O(1) and a song can never be selected twice.
  private var selectedSongIds: Set<String> = []

  public init() {}

  /// Number of songs currently selected.
  public var count: Int { selectedSongIds.count }

  /// Whether anything is selected (drives the toolbar action's enabled state).
  public var isEmpty: Bool { selectedSongIds.isEmpty }

  /// Whether the song with `id` is currently selected.
  public func isSelected(songId: String) -> Bool {
    selectedSongIds.contains(songId)
  }

  /// Marks the song selected. Idempotent.
  public func select(songId: String) {
    selectedSongIds.insert(songId)
  }

  /// Clears the song's selection. Idempotent.
  public func deselect(songId: String) {
    selectedSongIds.remove(songId)
  }

  /// Toggles the song's selection and returns the new state (`true` == now
  /// selected).
  @discardableResult
  public func toggle(songId: String) -> Bool {
    if selectedSongIds.contains(songId) {
      selectedSongIds.remove(songId)
      return false
    }
    selectedSongIds.insert(songId)
    return true
  }

  /// Drops every selection (used when leaving edit mode or after a successful
  /// add).
  public func clear() {
    selectedSongIds.removeAll()
  }

  /// Selects every song in `visibleSongs`, leaving any already-selected ids
  /// untouched. Scoped to the VISIBLE (filtered) list on purpose: with the
  /// "hide filed tracks" filter on, the visible list *is* the unfiled backlog,
  /// so "Select All" ticks exactly that and nothing that has scrolled out of
  /// existence. Backs the edit bar's "Select All" action.
  public func selectAll(visibleSongs: [Song]) {
    selectedSongIds.formUnion(visibleSongs.map(\.id))
  }

  /// Whether every song in `visibleSongs` is currently selected. Drives the
  /// edit bar's Select All ⇄ Deselect All label toggle. An empty visible list
  /// is treated as NOT all-selected so the button stays on "Select All" (and
  /// disabled) rather than flipping to "Deselect All" with nothing to clear.
  public func areAllSelected(in visibleSongs: [Song]) -> Bool {
    guard !visibleSongs.isEmpty else { return false }
    return visibleSongs.allSatisfy { selectedSongIds.contains($0.id) }
  }

  /// Reconciles the selection against the list the user can currently see:
  /// any selected id no longer present in `visibleSongs` is dropped. Call this
  /// after a live `refreshSongs()` so the count and the resolved selection
  /// never include rows that have scrolled out of existence (e.g. a track that
  /// was just filed and is now hidden by the triage filter).
  public func retainOnly(visibleSongs: [Song]) {
    let visibleIds = Set(visibleSongs.map(\.id))
    selectedSongIds.formIntersection(visibleIds)
  }

  /// Resolves the current selection back into concrete `Song`s, returned in
  /// the order they appear in `orderedSongs` (so a downstream "Add N to
  /// playlist" preserves list order rather than the arbitrary set order).
  public func selectedSongs(from orderedSongs: [Song]) -> [Song] {
    orderedSongs.filter { selectedSongIds.contains($0.id) }
  }
}
