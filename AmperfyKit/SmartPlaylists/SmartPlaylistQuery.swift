//
//  SmartPlaylistQuery.swift
//  AmperfyKit
//
//  The grouped boolean query model for Smart Playlists
//  (V1 spec 2026-08-17, V1.5 addendum §1: one level of AND/OR groups).
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

// MARK: - SmartPlaylistCombinator

/// How the items of one container (the top level, or one group) are combined.
///
/// A level is always *uniform*: pure AND or pure OR. Mixing is expressed by
/// nesting a group, which is why the builder flips every connector chip at a
/// level together.
public enum SmartPlaylistCombinator: String, Codable, Equatable, Sendable, CaseIterable {
  /// Every item must match (AND). The default everywhere, so a query built
  /// without touching a connector behaves exactly like a V1 query.
  case all
  /// At least one item must match (OR).
  case any

  /// The word on the connector chip between two items, and the joiner used by
  /// `summaryText`.
  public var conjunctionText: String {
    switch self {
    case .all: return "and"
    case .any: return "or"
    }
  }

  /// The word for a "Match ALL / ANY of the following" header.
  public var quantifierText: String {
    switch self {
    case .all: return "ALL"
    case .any: return "ANY"
    }
  }

  /// The other combinator — tapping a chip flips the whole level.
  public var toggled: SmartPlaylistCombinator {
    self == .all ? .any : .all
  }
}

// MARK: - SmartPlaylistRuleGroup

/// A parenthesised sub-expression: a flat list of rules with its own
/// combinator. Groups never contain groups — one nesting level is the whole
/// model, which keeps both the builder UI and the evaluator honest.
public struct SmartPlaylistRuleGroup: Codable, Equatable, Sendable {
  public var combinator: SmartPlaylistCombinator
  public var rules: [SmartPlaylistRule]

  public init(combinator: SmartPlaylistCombinator = .all, rules: [SmartPlaylistRule] = []) {
    self.combinator = combinator
    self.rules = rules
  }

  /// An empty group carries no meaning and is removed on save.
  public var isEmpty: Bool { rules.isEmpty }

  /// Repeatability is decided *per container*, so a group may hold its own
  /// single instance of a non-repeatable kind.
  public func canAddRule(ofKind kind: SmartPlaylistRule.Kind) -> Bool {
    kind.isRepeatable || !rules.contains { $0.kind == kind }
  }

  /// The group's rules joined by its combinator, without the surrounding
  /// parentheses (`SmartPlaylistQuery.summaryText` adds those).
  public var summaryText: String {
    rules.map { $0.displayText }.joined(separator: " \(combinator.conjunctionText) ")
  }
}

// MARK: - SmartPlaylistQueryItem

/// One entry at the top level: either a bare rule or a group of rules.
public enum SmartPlaylistQueryItem: Codable, Equatable, Sendable {
  case rule(SmartPlaylistRule)
  case group(SmartPlaylistRuleGroup)

  public var asRule: SmartPlaylistRule? {
    guard case let .rule(rule) = self else { return nil }
    return rule
  }

  public var asGroup: SmartPlaylistRuleGroup? {
    guard case let .group(group) = self else { return nil }
    return group
  }

  /// Every rule this item contributes, in order.
  public var rules: [SmartPlaylistRule] {
    switch self {
    case let .rule(rule): return [rule]
    case let .group(group): return group.rules
    }
  }

  /// True only for a group with no rules — the one shape that is dropped on
  /// save because it says nothing.
  public var isEmpty: Bool {
    guard case let .group(group) = self else { return false }
    return group.isEmpty
  }
}

// MARK: - SmartPlaylistQuery

/// A smart playlist query: a top-level container of items, each item a rule or
/// a one-level group, all combined by `combinator`.
///
/// # Codable / persistence
///
/// The encoded form is `{"combinator": "all", "items": [...]}`. V1 persisted a
/// flat `{"rules": [...]}` with an implicit AND, and those blobs are still in
/// shipped users' `UserDefaults` (build 83), so `init(from:)` decodes them into
/// a top-level `.all` container of bare rules. See
/// `SmartPlaylistStoreTest.testDecodesVersion1FlatQueryBlob` for the captured
/// raw-blob proof.
public struct SmartPlaylistQuery: Codable, Equatable, Sendable {
  /// How the top-level items combine.
  public var combinator: SmartPlaylistCombinator
  /// The top-level items, in display order.
  public var items: [SmartPlaylistQueryItem]

  public init(
    combinator: SmartPlaylistCombinator = .all,
    items: [SmartPlaylistQueryItem] = []
  ) {
    self.combinator = combinator
    self.items = items
  }

  /// Convenience for the V1 shape: a flat AND list of bare rules. Deliberately
  /// has no default argument so `SmartPlaylistQuery()` stays unambiguous.
  public init(rules: [SmartPlaylistRule]) {
    self.init(combinator: .all, items: rules.map { .rule($0) })
  }

  // MARK: - Flat view

  /// Every rule in the query, top-level rules and group rules alike, in order.
  public var allRules: [SmartPlaylistRule] {
    items.flatMap { $0.rules }
  }

  /// Flat V1-compatible view of the query.
  ///
  /// Reading yields `allRules`. **Writing replaces the entire top level with
  /// bare rules**, so any group is lost — it exists so pre-group call sites keep
  /// working during the UI migration, not as a supported editing API. Build the
  /// tree through `items` instead.
  public var rules: [SmartPlaylistRule] {
    get { allRules }
    set { items = newValue.map { .rule($0) } }
  }

  /// No rules anywhere — reads as "All songs".
  public var isEmpty: Bool { items.allSatisfy { $0.rules.isEmpty } }

  // MARK: - Refresher inputs

  /// The active added-within-days window, if any. The refresher uses this to
  /// decide whether a recent-songs backfill is needed and where to stop paging.
  /// If several such rules exist (one per container is allowed), the *widest*
  /// window wins so the backfill covers everything the query could match.
  public var addedWithinDays: Int? {
    allRules.compactMap { rule -> Int? in
      guard case let .addedWithinDays(days) = rule else { return nil }
      return days
    }.max()
  }

  /// Whether any rule depends on playlist membership. Drives the
  /// "sync unsynced playlists first" step of an online refresh, because
  /// `PlaylistItemMO` rows only exist for individually fetched playlists.
  public var requiresPlaylistItems: Bool {
    allRules.contains { $0.requiresPlaylistItems }
  }

  /// Whether evaluation will read the song's `album` relationship, so the
  /// candidate fetch prefetches it only when it pays for itself.
  public var requiresAlbumData: Bool {
    allRules.contains { $0.requiresAlbumData }
  }

  /// The ids of every playlist referenced by a membership rule.
  public var referencedPlaylistIds: [String] {
    allRules.compactMap { $0.referencedPlaylistId }
  }

  // MARK: - Builder support

  /// Whether a rule of this kind can still be added **to the top level**
  /// (single-instance kinds are offered only while absent from that container).
  /// Groups answer for themselves via `SmartPlaylistRuleGroup.canAddRule`.
  public func canAddRule(ofKind kind: SmartPlaylistRule.Kind) -> Bool {
    kind.isRepeatable || !items.contains { $0.asRule?.kind == kind }
  }

  /// Whether a rule of this kind can be added to the group at `groupIndex`.
  /// Returns `false` when the index is not a group.
  public func canAddRule(ofKind kind: SmartPlaylistRule.Kind, toGroupAt groupIndex: Int) -> Bool {
    guard items.indices.contains(groupIndex),
          let group = items[groupIndex].asGroup else { return false }
    return group.canAddRule(ofKind: kind)
  }

  /// Drops groups that hold no rules — call before persisting a user edit.
  public mutating func removeEmptyGroups() {
    items.removeAll { $0.isEmpty }
  }

  // MARK: - Display

  /// One-line rendering for the results header and the builder footer, with
  /// groups parenthesised, e.g.
  /// `"Added in the last 30 days and (Never played or In fewer than 2 playlists)"`.
  ///
  /// A one-rule group reads as the bare rule: parentheses around a single
  /// condition carry no information and only add noise. Empty groups are
  /// skipped entirely.
  public var summaryText: String {
    let parts = items.compactMap { item -> String? in
      switch item {
      case let .rule(rule):
        return rule.displayText
      case let .group(group):
        guard !group.rules.isEmpty else { return nil }
        return group.rules.count == 1 ? group.summaryText : "(\(group.summaryText))"
      }
    }
    guard !parts.isEmpty else { return "All songs" }
    return parts.joined(separator: " \(combinator.conjunctionText) ")
  }

  static func dayWord(_ days: Int) -> String {
    days == 1 ? "day" : "days"
  }

  // MARK: - Codable (with V1 flat-format migration)

  enum CodingKeys: String, CodingKey {
    case combinator
    case items
    /// V1 only. Never written any more, always read when `items` is absent.
    case rules
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.items) {
      self.combinator = try container.decodeIfPresent(
        SmartPlaylistCombinator.self,
        forKey: .combinator
      ) ?? .all
      self.items = try container.decode([SmartPlaylistQueryItem].self, forKey: .items)
    } else {
      // V1 (build 83) blob: a flat `rules` array with an implicit AND.
      self.combinator = .all
      let legacyRules = try container.decodeIfPresent(
        [SmartPlaylistRule].self,
        forKey: .rules
      ) ?? []
      self.items = legacyRules.map { .rule($0) }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(combinator, forKey: .combinator)
    try container.encode(items, forKey: .items)
  }
}
