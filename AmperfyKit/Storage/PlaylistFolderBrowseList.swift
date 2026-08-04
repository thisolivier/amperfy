//
//  PlaylistFolderBrowseList.swift
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

// MARK: - PlaylistFolderBrowseRowIdentity

/// Which sibling a browse-list row stands for. The browse list is one
/// interleaved list of folders and playlists, so a row index alone says nothing
/// about what kind of thing it is — every selection, drag and drop decision is
/// carried on this identity instead.
///
/// The string encoding exists so a drag item can carry the identity across the
/// `NSItemProvider` boundary and back without a bespoke serialization type.
public struct PlaylistFolderBrowseRowIdentity: Hashable, Sendable {
  public let kind: PlaylistFolderSiblingKind
  /// Folder id or playlist id, matching `kind`. Folder ids are the server ids —
  /// the same strings `PlaylistFolderSibling` carries.
  public let id: String

  public init(kind: PlaylistFolderSiblingKind, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func folder(_ folderId: String) -> Self {
    Self(kind: .folder, id: folderId)
  }

  public static func playlist(_ playlistId: String) -> Self {
    Self(kind: .playlist, id: playlistId)
  }

  /// `"folder:<id>"` / `"playlist:<id>"`.
  public var encodedString: String {
    "\(kind.rawValue):\(id)"
  }

  /// Decodes ``encodedString``. The id may itself contain colons (nothing in the
  /// contract forbids it), so only the first separator is significant.
  public init?(encodedString: String) {
    guard let separatorIndex = encodedString.firstIndex(of: ":") else { return nil }
    let kindFragment = String(encodedString[encodedString.startIndex ..< separatorIndex])
    let idFragment = String(encodedString[encodedString.index(after: separatorIndex)...])
    guard let kind = PlaylistFolderSiblingKind(rawValue: kindFragment), !idFragment.isEmpty
    else { return nil }
    self.init(kind: kind, id: idFragment)
  }
}

// MARK: - PlaylistFolderBrowseListBuilder

/// Turns a parent's folders and playlists into the single interleaved row order
/// the browse screens render.
///
/// PR 2 rendered folders and playlists as two sections that each projected the
/// shared sibling order onto their own members. That reads correctly per section
/// but loses the actual arrangement: a playlist deliberately placed between two
/// folders appeared below both. Interleaving is the whole point of one ordering
/// space per parent, so the list is built from it directly.
///
/// Attribute sorts (name, last played, duration, …) are a different question:
/// they have no meaning for folders, and mixing a folder into a duration sort
/// would be arbitrary. Under an attribute sort the caller passes
/// `keepsFoldersFirst: true`, which puts the folders — name-ordered — ahead of
/// the playlists in the caller's chosen order, still as one list.
public enum PlaylistFolderBrowseListBuilder {
  /// The interleaved row order for one parent.
  ///
  /// - Parameters:
  ///   - folderSiblings: the parent's subfolders.
  ///   - playlistSiblings: the playlists placed directly in the parent, already
  ///     filtered by whatever the view hides (offline, search, smart playlists).
  ///   - keepsFoldersFirst: `true` when an attribute sort is active, in which
  ///     case the two given orders are concatenated rather than merged.
  public static func rowIdentities(
    folderSiblings: [PlaylistFolderSibling],
    playlistSiblings: [PlaylistFolderSibling],
    keepsFoldersFirst: Bool = false
  )
    -> [PlaylistFolderBrowseRowIdentity] {
    guard !keepsFoldersFirst else {
      return (folderSiblings + playlistSiblings).map(identity(of:))
    }
    return PlaylistFolderOrdering
      .sorted(folderSiblings + playlistSiblings)
      .map(identity(of:))
  }

  private static func identity(of sibling: PlaylistFolderSibling)
    -> PlaylistFolderBrowseRowIdentity {
    PlaylistFolderBrowseRowIdentity(kind: sibling.kind, id: sibling.id)
  }

  /// The index a row identity occupies in a built row list, or `nil` when the
  /// row is not currently shown (filtered out by search or offline mode).
  public static func rowIndex(
    of identity: PlaylistFolderBrowseRowIdentity,
    in rowIdentities: [PlaylistFolderBrowseRowIdentity]
  )
    -> Int? {
    rowIdentities.firstIndex(of: identity)
  }
}
