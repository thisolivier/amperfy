//
//  SmartPlaylistQuery+BuilderEditing.swift
//  Amperfy
//
//  Tree-safe editing operations the smart playlist builder performs on a query
//  (V1.5 addendum §1, 2026-08-17).
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

// MARK: - SmartPlaylistRule.Kind + defaultRule

extension SmartPlaylistRule.Kind {
  /// The rule a freshly added row starts as.
  ///
  /// `nil` for the playlist-membership kinds: a membership rule is meaningless
  /// without a playlist, so those are only created once one has been picked.
  var defaultRule: SmartPlaylistRule? {
    switch self {
    case .addedWithinDays: return .addedWithinDays(30)
    case .completeAlbum: return .completeAlbum(isComplete: true)
    case .inPlaylist, .notInPlaylist: return nil
    case .played: return .played(.never)
    case .playlistCount: return .playlistCount(comparison: .fewerThan, count: 1)
    }
  }
}

// MARK: - SmartPlaylistQuery + builder editing

/// Every edit the builder makes goes through here, and every one of them works
/// on `items`.
///
/// This exists to keep the builder away from `SmartPlaylistQuery.rules`, whose
/// setter flattens the whole tree into bare top-level rules and silently
/// destroys groups — it is a read-only-shaped compatibility shim for pre-group
/// call sites, not an editing API.
extension SmartPlaylistQuery {
  // MARK: - Reading

  func rule(at location: SmartPlaylistBuilderRuleLocation) -> SmartPlaylistRule? {
    switch location {
    case let .group(itemIndex, ruleIndex):
      return group(at: itemIndex)?.rules.element(at: ruleIndex)
    case let .topLevel(itemIndex):
      return items.element(at: itemIndex)?.asRule
    }
  }

  func group(at itemIndex: Int) -> SmartPlaylistRuleGroup? {
    items.element(at: itemIndex)?.asGroup
  }

  /// The rule kinds still addable to a container, in menu order.
  func addableRuleKinds(forGroupAt itemIndex: Int?) -> [SmartPlaylistRule.Kind] {
    SmartPlaylistRule.Kind.allCases.filter { ruleKind in
      guard let itemIndex else { return canAddRule(ofKind: ruleKind) }
      return canAddRule(ofKind: ruleKind, toGroupAt: itemIndex)
    }
  }

  // MARK: - Rules

  mutating func appendTopLevelRule(_ newRule: SmartPlaylistRule) {
    items.append(.rule(newRule))
  }

  mutating func appendRule(_ newRule: SmartPlaylistRule, toGroupAt itemIndex: Int) {
    guard var editedGroup = group(at: itemIndex) else { return }
    editedGroup.rules.append(newRule)
    items[itemIndex] = .group(editedGroup)
  }

  mutating func replaceRule(
    at location: SmartPlaylistBuilderRuleLocation,
    with newRule: SmartPlaylistRule
  ) {
    switch location {
    case let .group(itemIndex, ruleIndex):
      guard var editedGroup = group(at: itemIndex),
            editedGroup.rules.indices.contains(ruleIndex) else { return }
      editedGroup.rules[ruleIndex] = newRule
      items[itemIndex] = .group(editedGroup)
    case let .topLevel(itemIndex):
      guard items.element(at: itemIndex)?.asRule != nil else { return }
      items[itemIndex] = .rule(newRule)
    }
  }

  /// Deletes one rule. A group emptied this way is deliberately kept on screen
  /// with its "+ Add rule" row — the user is mid-edit, and `removeEmptyGroups()`
  /// clears anything still empty when the query is run.
  mutating func removeRule(at location: SmartPlaylistBuilderRuleLocation) {
    switch location {
    case let .group(itemIndex, ruleIndex):
      guard var editedGroup = group(at: itemIndex),
            editedGroup.rules.indices.contains(ruleIndex) else { return }
      editedGroup.rules.remove(at: ruleIndex)
      items[itemIndex] = .group(editedGroup)
    case let .topLevel(itemIndex):
      guard items.indices.contains(itemIndex) else { return }
      items.remove(at: itemIndex)
    }
  }

  // MARK: - Groups

  mutating func appendGroup(withFirstRule firstRule: SmartPlaylistRule) {
    items.append(.group(SmartPlaylistRuleGroup(combinator: .all, rules: [firstRule])))
  }

  mutating func removeGroup(at itemIndex: Int) {
    guard items.element(at: itemIndex)?.asGroup != nil else { return }
    items.remove(at: itemIndex)
  }

  mutating func setCombinator(
    _ newCombinator: SmartPlaylistCombinator,
    ofGroupAt itemIndex: Int
  ) {
    guard var editedGroup = group(at: itemIndex) else { return }
    editedGroup.combinator = newCombinator
    items[itemIndex] = .group(editedGroup)
  }

  // MARK: - Connector chips

  /// Flips the top level between and/or. Every chip at the level renders the
  /// same value, so one tap moves them all — that is the whole point of the
  /// uniform-per-level model.
  mutating func toggleTopLevelCombinator() {
    combinator = combinator.toggled
  }

  mutating func toggleCombinator(ofGroupAt itemIndex: Int) {
    guard let existingGroup = group(at: itemIndex) else { return }
    setCombinator(existingGroup.combinator.toggled, ofGroupAt: itemIndex)
  }
}
