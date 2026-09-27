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

/// Which sibling a browse-list row stands for. The browse list is one list of
/// folders and playlists (folder block first), so a row index alone says nothing
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

/// Turns a parent's folders and playlists into the single row order the browse
/// screens render: the folder block first, then the playlist block, under every
/// sort option.
///
/// Folders always render ahead of playlists, segregated — never mixed. The two
/// kinds still share one `sortOrder` space per parent (the server contract),
/// but the sibling comparator applies kind precedence before sortOrder, so the
/// blocks fall out of one sort. An earlier design interleaved the kinds by raw
/// sortOrder; on a fresh install, where nothing has a sortOrder yet, that
/// degenerated to an alphabetical mix of folders and playlists that then
/// reshuffled on the first reorder.
///
/// Attribute sorts (name, last played, duration, …) have no meaning for
/// folders. Under an attribute sort the caller passes `keepsFoldersFirst:
/// true`, which concatenates the folders — name-ordered by the caller — ahead
/// of the playlists in the caller's chosen order, rather than re-sorting.
public enum PlaylistFolderBrowseListBuilder {
  /// The row order for one parent: folders first, then playlists.
  ///
  /// - Parameters:
  ///   - folderSiblings: the parent's subfolders.
  ///   - playlistSiblings: the playlists placed directly in the parent, already
  ///     filtered by whatever the view hides (offline, search, smart playlists).
  ///   - keepsFoldersFirst: `true` when an attribute sort is active, in which
  ///     case the two given orders are concatenated as-is rather than sorted
  ///     with the sibling comparator.
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
