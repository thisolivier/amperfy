//
//  PlaylistFolderStore+Batching.swift
//  AmperfyKit
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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

/// Coalescing for bulk organization.
///
/// Every single-item write path already ends in `notifyChange()` +
/// `exportCurrentTree()`, and that pairing is exactly what makes the JSON safety
/// net trustworthy — it fires on the same line as the mutation, so it cannot be
/// forgotten. Bulk operations must keep using those same write paths rather than
/// growing parallel ones, so instead of teaching each caller to suppress the
/// tail, the store defers it: run the mutations inside
/// ``performBatchedUpdates(_:)`` and the notification and the export happen once,
/// after the last one.
///
/// The export is the load-bearing half. `PlaylistFolderTreeExporter` keeps two
/// generations, rolling current → previous on each write; a 40-playlist move
/// exporting per item would roll the last good pre-move snapshot out of
/// existence 40 times over, leaving the "previous" copy one item behind the
/// current one rather than one *operation* behind it.
extension PlaylistFolderStore {
  /// Run `mutations`, coalescing the change notification and the tree export
  /// they trigger into one of each at the end.
  ///
  /// Nesting is supported and only the outermost call flushes, so a bulk helper
  /// may be built out of other bulk helpers without either of them having to
  /// know it is not the top of the stack.
  public func performBatchedUpdates(_ mutations: () -> ()) {
    batchedUpdateDepth += 1
    mutations()
    batchedUpdateDepth -= 1
    guard batchedUpdateDepth == 0 else { return }

    let shouldExport = hasDeferredTreeExport
    let shouldNotify = hasDeferredChangeNotification
    hasDeferredTreeExport = false
    hasDeferredChangeNotification = false

    if shouldExport { exportCurrentTree() }
    if shouldNotify { notifyChange() }
  }
}
