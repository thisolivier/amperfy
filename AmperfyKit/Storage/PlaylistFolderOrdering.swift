//
//  PlaylistFolderOrdering.swift
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

// MARK: - PlaylistFolderSiblingKind

/// Sibling folders and sibling playlists share a single ordering space per
/// parent, so both kinds sort against each other rather than in separate lists.
public enum PlaylistFolderSiblingKind: String, Sendable, Equatable, Codable {
  case folder
  case playlist
}

// MARK: - PlaylistFolderSibling

/// One entry in a parent's ordering space — either a subfolder or a playlist
/// placed in that parent.
public struct PlaylistFolderSibling: Sendable, Equatable, Identifiable {
  public let kind: PlaylistFolderSiblingKind
  /// Folder id or playlist id, depending on `kind`.
  public let id: String
  /// Display name, used as the tie-break when two siblings share a `sortOrder`.
  public let name: String
  /// Client-assigned ordering key. `nil` means unordered; unordered siblings
  /// sort after every ordered one.
  public let sortOrder: Int?

  public init(
    kind: PlaylistFolderSiblingKind,
    id: String,
    name: String,
    sortOrder: Int?
  ) {
    self.kind = kind
    self.id = id
    self.name = name
    self.sortOrder = sortOrder
  }
}

// MARK: - PlaylistFolderSortOrderAssignment

/// A sortOrder the client must push to the server for an existing sibling,
/// produced when an insertion runs out of gap and the siblings need renumbering.
public struct PlaylistFolderSortOrderAssignment: Sendable, Equatable {
  public let kind: PlaylistFolderSiblingKind
  public let id: String
  public let sortOrder: Int

  public init(kind: PlaylistFolderSiblingKind, id: String, sortOrder: Int) {
    self.kind = kind
    self.id = id
    self.sortOrder = sortOrder
  }
}

// MARK: - PlaylistFolderSortOrderPlan

/// How to give an item the sortOrder that lands it at a requested position.
public enum PlaylistFolderSortOrderPlan: Sendable, Equatable {
  /// A gap was available: give the item this sortOrder and touch nothing else.
  case assign(sortOrder: Int)
  /// No gap remained (or the neighbours were unordered). Every sibling listed in
  /// `assignments` must be updated through its own update endpoint, and the
  /// inserted item takes `insertedSortOrder`.
  case renumberSiblings(
    assignments: [PlaylistFolderSortOrderAssignment],
    insertedSortOrder: Int
  )
}

// MARK: - PlaylistFolderOrdering

/// The sibling comparator and the gap-numbering scheme, kept pure so both can be
/// tested without Core Data or a server.
///
/// ## Ordering
/// Within one parent, siblings sort by `sortOrder` ascending, ties broken by
/// name, and siblings without a `sortOrder` come after every ordered one (also
/// name-sorted among themselves). Folders and playlists interleave — they are
/// one space, not two. The root is a parent like any other: playlists with an
/// explicit root placement are ordered, and playlists with no placement at all
/// are the unordered tail.
///
/// ## Gap numbering
/// sortOrder values are client-assigned, unnormalized, and duplicates are legal,
/// so ordering never requires rewriting the whole sibling list. Appending takes
/// the highest sibling order plus ``sortOrderGap``; inserting takes the midpoint
/// of its two neighbours. Only when two neighbours are adjacent integers — no
/// midpoint exists — do the siblings get renumbered onto a fresh gap scale.
public enum PlaylistFolderOrdering {
  /// Spacing left between consecutive siblings so later inserts have a midpoint.
  public static let sortOrderGap = 10

  // MARK: - Comparator

  /// Whether `lhs` sorts before `rhs` among siblings of the same parent.
  public static func isOrderedBefore(
    _ lhs: PlaylistFolderSibling,
    _ rhs: PlaylistFolderSibling
  )
    -> Bool {
    switch (lhs.sortOrder, rhs.sortOrder) {
    case let (leftSortOrder?, rightSortOrder?):
      if leftSortOrder != rightSortOrder { return leftSortOrder < rightSortOrder }
      return isNameOrderedBefore(lhs, rhs)
    case (.some, .none):
      // Ordered siblings always precede unordered ones.
      return true
    case (.none, .some):
      return false
    case (.none, .none):
      return isNameOrderedBefore(lhs, rhs)
    }
  }

  /// Name tie-break. Falls through to id so the comparator stays a strict weak
  /// ordering even when two siblings share a name.
  private static func isNameOrderedBefore(
    _ lhs: PlaylistFolderSibling,
    _ rhs: PlaylistFolderSibling
  )
    -> Bool {
    let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
    return lhs.id < rhs.id
  }

  /// Siblings of one parent in display order.
  public static func sorted(_ siblings: [PlaylistFolderSibling]) -> [PlaylistFolderSibling] {
    siblings.sorted(by: isOrderedBefore)
  }

  // MARK: - Gap numbering

  /// The sortOrder for an item appended after every existing sibling: the
  /// highest sibling order plus one gap, or the first gap when nothing is
  /// ordered yet.
  public static func appendSortOrder(after siblings: [PlaylistFolderSibling]) -> Int {
    let highestExistingSortOrder = siblings.compactMap(\.sortOrder).max()
    guard let highestExistingSortOrder else { return sortOrderGap }
    return highestExistingSortOrder + sortOrderGap
  }

  /// Plan the sortOrder for an item being placed at `targetIndex` within
  /// `siblings`.
  ///
  /// - Parameters:
  ///   - siblings: the parent's current siblings, *excluding* the item being
  ///     placed. Need not be pre-sorted.
  ///   - targetIndex: the index the item should occupy in the sorted sibling
  ///     list once inserted, from `0` (first) to `siblings.count` (last).
  public static func insertionPlan(
    into siblings: [PlaylistFolderSibling],
    targetIndex: Int
  )
    -> PlaylistFolderSortOrderPlan {
    let sortedSiblings = sorted(siblings)
    let clampedIndex = min(max(targetIndex, 0), sortedSiblings.count)

    let precedingSortOrder = clampedIndex > 0
      ? sortedSiblings[clampedIndex - 1].sortOrder : nil
    let followingSortOrder = clampedIndex < sortedSiblings.count
      ? sortedSiblings[clampedIndex].sortOrder : nil

    switch (precedingSortOrder, followingSortOrder) {
    case (nil, nil):
      // Either the parent is empty, or the insertion point sits inside the
      // unordered tail — there is no anchor to compute a midpoint from.
      if sortedSiblings.isEmpty { return .assign(sortOrder: sortOrderGap) }
      return renumberPlan(sortedSiblings: sortedSiblings, insertingAt: clampedIndex)

    case let (precedingSortOrder?, nil):
      // Appending after the last ordered sibling. Any unordered tail keeps
      // sorting after it, so no renumber is needed.
      return .assign(sortOrder: precedingSortOrder + sortOrderGap)

    case let (nil, followingSortOrder?):
      // Inserting before everything: step a full gap below the current head.
      return .assign(sortOrder: followingSortOrder - sortOrderGap)

    case let (precedingSortOrder?, followingSortOrder?):
      guard followingSortOrder - precedingSortOrder > 1 else {
        // Adjacent (or duplicate) integers — no midpoint exists.
        return renumberPlan(sortedSiblings: sortedSiblings, insertingAt: clampedIndex)
      }
      let midpoint = precedingSortOrder + (followingSortOrder - precedingSortOrder) / 2
      return .assign(sortOrder: midpoint)
    }
  }

  /// Rebuild the whole sibling list onto a fresh gap scale, leaving a slot at
  /// `insertionIndex` for the incoming item. Only siblings whose sortOrder
  /// actually changes are reported, so the caller issues the fewest updates.
  private static func renumberPlan(
    sortedSiblings: [PlaylistFolderSibling],
    insertingAt insertionIndex: Int
  )
    -> PlaylistFolderSortOrderPlan {
    var assignments = [PlaylistFolderSortOrderAssignment]()
    var nextSortOrder = sortOrderGap
    var insertedSortOrder = sortOrderGap

    for (index, sibling) in sortedSiblings.enumerated() {
      if index == insertionIndex {
        insertedSortOrder = nextSortOrder
        nextSortOrder += sortOrderGap
      }
      if sibling.sortOrder != nextSortOrder {
        assignments.append(PlaylistFolderSortOrderAssignment(
          kind: sibling.kind,
          id: sibling.id,
          sortOrder: nextSortOrder
        ))
      }
      nextSortOrder += sortOrderGap
    }
    if insertionIndex >= sortedSiblings.count {
      insertedSortOrder = nextSortOrder
    }

    return .renumberSiblings(
      assignments: assignments,
      insertedSortOrder: insertedSortOrder
    )
  }
}
