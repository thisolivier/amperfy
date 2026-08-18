//
//  SmartPlaylistBuilderRowLayout.swift
//  Amperfy
//
//  Turns a grouped smart playlist query into the builder table's sections and
//  rows (V1.5 addendum §1, 2026-08-17).
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

import AmperfyKit
import Foundation

// MARK: - SmartPlaylistBuilderRuleLocation

/// Where one rule sits in the query tree.
///
/// Rows carry a location rather than a flat rule index because the same kind of
/// row appears at two levels, and a flat index cannot say which container a rule
/// belongs to — which matters for per-container repeatability, deletion and
/// in-place editing alike.
enum SmartPlaylistBuilderRuleLocation: Equatable {
  case topLevel(itemIndex: Int)
  case group(itemIndex: Int, ruleIndex: Int)
}

// MARK: - SmartPlaylistBuilderRow

/// One row of the builder table. Every visible thing is a real row (or a real
/// section header) rather than a decoration drawn inside another row, so each
/// one is its own accessibility element and swipe-to-delete keeps working.
enum SmartPlaylistBuilderRow: Equatable {
  /// A bare rule at the top level; its whole section is this one row.
  case topLevelRule(itemIndex: Int)
  /// The first row of a group card: the group's combinator plus its ⋯ menu.
  case groupHeader(itemIndex: Int)
  /// An and/or chip between two of a group's rules.
  case groupConnector(itemIndex: Int, precedingRuleIndex: Int)
  case groupRule(itemIndex: Int, ruleIndex: Int)
  /// The group's own "+ Add rule" row.
  case groupAddRule(itemIndex: Int)
  /// The trailing "+ Add rule" / "+ Add group" pair.
  case actions

  var ruleLocation: SmartPlaylistBuilderRuleLocation? {
    switch self {
    case .actions, .groupAddRule, .groupConnector, .groupHeader:
      return nil
    case let .groupRule(itemIndex, ruleIndex):
      return .group(itemIndex: itemIndex, ruleIndex: ruleIndex)
    case let .topLevelRule(itemIndex):
      return .topLevel(itemIndex: itemIndex)
    }
  }

  /// The group this row belongs to, if any — the one input the inset card
  /// styling and the group-scoped menus need.
  var groupItemIndex: Int? {
    switch self {
    case .actions, .topLevelRule:
      return nil
    case let .groupAddRule(itemIndex),
         let .groupConnector(itemIndex, _),
         let .groupHeader(itemIndex),
         let .groupRule(itemIndex, _):
      return itemIndex
    }
  }

  /// Whether the row is drawn as part of a group card (inset + tinted).
  var isInsideGroupCard: Bool { groupItemIndex != nil }
}

// MARK: - SmartPlaylistBuilderSectionHeader

/// What sits above a section.
///
/// The top level's connector chips are section headers, not rows, because each
/// top-level item is its own inset card — the only place a chip can live
/// *between* two cards is the gap the next section's header occupies.
enum SmartPlaylistBuilderSectionHeader: Equatable {
  /// The form's one plain title, above the first section.
  case title
  /// An and/or chip joining the previous top-level item to this one.
  case connector
  /// Plain spacing, so the section below does not butt up against the one above.
  case spacing
}

// MARK: - SmartPlaylistBuilderRowLayout

/// The pure structural mapping from a query to the table's shape. Holds no
/// UIKit and no query state beyond what it was built from, so the view
/// controller can rebuild it wholesale after every edit.
struct SmartPlaylistBuilderRowLayout {
  private(set) var sections: [[SmartPlaylistBuilderRow]] = []
  /// Number of top-level items; the actions section is the one after them.
  private let itemCount: Int

  init(query: SmartPlaylistQuery) {
    self.itemCount = query.items.count
    self.sections = query.items.enumerated().map { itemIndex, item in
      Self.rows(for: item, at: itemIndex)
    }
    sections.append([.actions])
  }

  private static func rows(
    for item: SmartPlaylistQueryItem,
    at itemIndex: Int
  )
    -> [SmartPlaylistBuilderRow] {
    guard let group = item.asGroup else {
      return [.topLevelRule(itemIndex: itemIndex)]
    }
    var groupRows: [SmartPlaylistBuilderRow] = [.groupHeader(itemIndex: itemIndex)]
    for ruleIndex in group.rules.indices {
      if ruleIndex > 0 {
        groupRows.append(.groupConnector(
          itemIndex: itemIndex,
          precedingRuleIndex: ruleIndex - 1
        ))
      }
      groupRows.append(.groupRule(itemIndex: itemIndex, ruleIndex: ruleIndex))
    }
    groupRows.append(.groupAddRule(itemIndex: itemIndex))
    return groupRows
  }

  var numberOfSections: Int { sections.count }

  /// The trailing actions section, which also carries the live query summary as
  /// its footer.
  var actionsSectionIndex: Int { sections.count - 1 }

  func numberOfRows(inSection sectionIndex: Int) -> Int {
    sections.element(at: sectionIndex)?.count ?? 0
  }

  func row(at indexPath: IndexPath) -> SmartPlaylistBuilderRow? {
    sections.element(at: indexPath.section)?.element(at: indexPath.row)
  }

  func header(forSection sectionIndex: Int) -> SmartPlaylistBuilderSectionHeader {
    if sectionIndex == 0 { return .title }
    // Every top-level item after the first is preceded by a connector; the
    // trailing actions section is not part of the boolean expression, so it
    // gets plain spacing instead.
    return sectionIndex < itemCount ? .connector : .spacing
  }
}
