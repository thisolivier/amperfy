//
//  PendingPlaylistSongAdd.swift
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

/// One song the user put into one playlist, recorded until the server confirms
/// it.
///
/// The row exists for exactly as long as the add is unproven. It is created in
/// the same save as the optimistic local append and deleted either when the
/// upload lands or when the server permanently refuses it — in which case the
/// local append is rolled back, so what the user sees never silently diverges
/// from what the server holds.
public class PendingPlaylistSongAdd: NSObject {
  let managedObject: PendingPlaylistSongAddMO
  private let library: LibraryStorage

  public init(library: LibraryStorage, managedObject: PendingPlaylistSongAddMO) {
    self.library = library
    self.managedObject = managedObject
  }

  public var objectID: NSManagedObjectID { managedObject.objectID }

  public var account: Account? {
    get {
      guard let accountMO = managedObject.account else { return nil }
      return Account(managedObject: accountMO)
    }
    set {
      if managedObject.account != newValue?
        .managedObject { managedObject.account = newValue?.managedObject }
    }
  }

  public var createdAt: Date? {
    get { managedObject.createdAt }
    set { managedObject.createdAt = newValue }
  }

  public var attemptCount: Int {
    get { Int(managedObject.attemptCount) }
    set { managedObject.attemptCount = Int32(newValue) }
  }

  public var lastErrorMessage: String? {
    get { managedObject.lastErrorMessage }
    set { managedObject.lastErrorMessage = newValue }
  }

  public var playlist: Playlist? {
    get {
      guard let playlistMO = managedObject.playlist else { return nil }
      return Playlist(library: library, managedObject: playlistMO)
    }
    set { managedObject.playlist = newValue?.managedObject }
  }

  public var song: Song? {
    get {
      guard let songMO = managedObject.playable as? SongMO else { return nil }
      return Song(managedObject: songMO)
    }
    set { managedObject.playable = newValue?.managedObject }
  }

  /// `true` when either end of the add has gone away locally — a library wipe,
  /// an account removal, a playlist deleted on another device — or when the
  /// queued playable is not a song, which is the only thing a playlist upload
  /// can carry. Such an add can never be sent and is swept instead of retried
  /// forever.
  public var isOrphaned: Bool {
    managedObject.account == nil || managedObject.playlist == nil ||
      !(managedObject.playable is SongMO)
  }

  override public func isEqual(_ object: Any?) -> Bool {
    guard let object = object as? PendingPlaylistSongAdd else { return false }
    return managedObject == object.managedObject
  }

  override public var hash: Int {
    managedObject.hashValue
  }
}
