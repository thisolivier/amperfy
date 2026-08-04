//
//  PlaylistFolderAdoption.swift
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

// MARK: - PlaylistFolderAdoption

/// A folder swapping its temporary local id for the one the server assigned.
///
/// Carried on `PlaylistFolderStore.didAdoptFolderIdNotification`. The payload
/// follows `DownloadNotification`'s shape — a struct that knows how to become a
/// `userInfo` dictionary and how to come back out of one — so nothing outside
/// this file handles raw dictionary keys.
public struct PlaylistFolderAdoption: Sendable, Equatable {
  /// The id the folder was created under, now dead.
  public let temporaryFolderId: String
  /// The id the server assigned, live from here on.
  public let serverFolderId: String

  public init(temporaryFolderId: String, serverFolderId: String) {
    self.temporaryFolderId = temporaryFolderId
    self.serverFolderId = serverFolderId
  }

  public var asNotificationUserInfo: [String: Any] {
    [
      Self.temporaryFolderIdKey: temporaryFolderId,
      Self.serverFolderIdKey: serverFolderId,
    ]
  }

  public static func fromNotification(_ notification: Notification) -> PlaylistFolderAdoption? {
    guard let userInfo = notification.userInfo as? [String: Any],
          let temporaryFolderId = userInfo[temporaryFolderIdKey] as? String,
          let serverFolderId = userInfo[serverFolderIdKey] as? String
    else { return nil }
    return PlaylistFolderAdoption(
      temporaryFolderId: temporaryFolderId,
      serverFolderId: serverFolderId
    )
  }

  private static let temporaryFolderIdKey = "temporaryFolderId"
  private static let serverFolderIdKey = "serverFolderId"
}

// MARK: - PlaylistFolderScopeBinding

/// The folder a screen is scoped to, which has to survive that folder adopting a
/// new id underneath it.
///
/// A browse screen pushed for a freshly created folder holds the temporary id.
/// When the create lands, that id stops resolving — the folder is still there,
/// under a different name for it. Without rebinding, the screen's next reload
/// finds nothing and pops the user out of a folder they are working in.
///
/// This is a value type rather than logic inside the view controller so it can be
/// tested: the app target is not visible to `AmperfyKitTests`, and the rule —
/// rebind on a match, ignore everything else — is the part worth pinning.
public struct PlaylistFolderScopeBinding: Equatable, Sendable {
  /// The folder being browsed, or `nil` for the root, which never adopts.
  public private(set) var scopedFolderId: String?

  public init(scopedFolderId: String?) {
    self.scopedFolderId = scopedFolderId
  }

  /// Apply an adoption event.
  ///
  /// - Returns: `true` when this binding's folder was the one that adopted, so
  ///   the caller knows to reload rather than reloading on every adoption in the
  ///   tree.
  @discardableResult
  public mutating func apply(_ adoption: PlaylistFolderAdoption) -> Bool {
    guard scopedFolderId == adoption.temporaryFolderId else { return false }
    scopedFolderId = adoption.serverFolderId
    return true
  }
}
