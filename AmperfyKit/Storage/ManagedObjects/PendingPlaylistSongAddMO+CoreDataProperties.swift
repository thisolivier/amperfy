//
//  PendingPlaylistSongAddMO+CoreDataProperties.swift
//  AmperfyKit
//
//  Created by Olivier Butler on 23.10.26.
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

  /// How many upload attempts this add has survived. Diagnostics only: there is
  /// deliberately no ceiling, a song the user put into a playlist is not
  /// something to stop trying to deliver.
  @NSManaged
  public var attemptCount: Int32
  /// When the user made the add. Drives the FIFO order, so songs reach the
  /// server in the order they were selected.
  @NSManaged
  public var createdAt: Date?
  /// The last transient failure's description, kept for the log.
  @NSManaged
  public var lastErrorMessage: String?
  @NSManaged
  public var account: AccountMO?
  /// The song to add. A relationship rather than a stored id, so the add keeps
  /// pointing at the right song even if the server reassigns its id.
  @NSManaged
  public var playable: AbstractPlayableMO?
  /// The target playlist. Also a relationship, and for a sharper reason: a
  /// freshly created playlist has an empty server id until its create request
  /// round-trips, so an id captured at queueing time could name nothing at all.
  @NSManaged
  public var playlist: PlaylistMO?
}
