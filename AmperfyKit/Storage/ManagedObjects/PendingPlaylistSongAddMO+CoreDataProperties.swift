//
//  PendingPlaylistSongAddMO+CoreDataProperties.swift
//  AmperfyKit
//
//  Created for AMP-28 — playlist song adds became a durable, retried queue.
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

import CoreData
import Foundation

extension PendingPlaylistSongAddMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<PendingPlaylistSongAddMO> {
    NSFetchRequest<PendingPlaylistSongAddMO>(entityName: "PendingPlaylistSongAdd")
  }

  /// How many upload attempts this row has survived. Diagnostics only — there
  /// is deliberately no ceiling: a song the user put in a playlist is not
  /// something to give up on (same rule as pending folder creations).
  @NSManaged
  public var attemptCount: Int32
  /// When the user made the add. Drives FIFO ordering so songs reach the
  /// server in the order they were tapped.
  @NSManaged
  public var createdAt: Date?
  /// The last transient failure's description, for the log and for the loud
  /// alert's "server reason" line.
  @NSManaged
  public var lastErrorMessage: String?
  @NSManaged
  public var account: AccountMO?
  /// The song to add. A relationship rather than a stored id: this fork has
  /// already lived through a server-wide track-id switchover (build 97), and
  /// object identity survives that where a copied id string would not.
  @NSManaged
  public var playable: AbstractPlayableMO?
  /// The target playlist. Also a relationship, and for a sharper reason: a
  /// freshly created playlist has an EMPTY server id until its create request
  /// round-trips, so an id captured at enqueue time could name nothing at all.
  @NSManaged
  public var playlist: PlaylistMO?
}
