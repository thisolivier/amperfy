//
//  SmartPlaylistQuery.swift
//  AmperfyKit
//
//  Rule model for the on-device Smart Playlists feature (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistPlayedRule

/// The "play data" dimension of a smart playlist query.
///
/// Play data is the *merged* view: the server's `playCount`/`played` values are
/// folded into the local `playCount`/`lastPlayedDate` fields at parse time
/// (`SsSongParserDelegate`), so a rule here sees both local offline plays and
/// plays that happened on other clients.
public enum SmartPlaylistPlayedRule: Codable, Equatable, Sendable {
  /// Never played on any client (`playCount == 0`).
  case never
  /// Not played within the last N days — includes songs never played at all
  /// (`lastPlayedDate == nil`).
  case notInLastDays(Int)
  /// Played within the last N days.
  case inLastDays(Int)

  public var displayText: String {
    switch self {
    case .never:
      return "Never played"
    case let .notInLastDays(days):
      return "Not played in the last \(days) \(SmartPlaylistQuery.dayWord(days))"
    case let .inLastDays(days):
      return "Played in the last \(days) \(SmartPlaylistQuery.dayWord(days))"
    }
  }
}

// MARK: - SmartPlaylistCountComparison

/// How a playlist-membership count is compared against a threshold.
public enum SmartPlaylistCountComparison: String, Codable, Equatable, Sendable, CaseIterable {
  case fewerThan
  case moreThan

  public var displayText: String {
    switch self {
    case .fewerThan: return "fewer than"
    case .moreThan: return "more than"
    }
  }
}

// MARK: - SmartPlaylistRule

/// One AND-combined rule of a smart playlist query.
///
/// Playlist rules carry the playlist's *display name* alongside its id so the
/// builder and the query summary render correctly offline. The name is a
/// snapshot for display only — evaluation always resolves by id, and a rule
/// whose playlist has vanished is dropped at evaluation time (and reported back
/// so the UI can flag it).
public enum SmartPlaylistRule: Codable, Equatable, Sendable {
  /// Song was added to the library within the last N days. Songs whose
  /// `addedDate` is unknown (`nil`) never match — the count of those is
  /// surfaced separately so the user understands the gap.
  case addedWithinDays(Int)
  /// Play-data rule, see `SmartPlaylistPlayedRule`.
  case played(SmartPlaylistPlayedRule)
  /// The song sits in fewer/more than N real user playlists.
  case playlistCount(comparison: SmartPlaylistCountComparison, count: Int)
  /// The song is absent from the named playlist.
  case notInPlaylist(playlistId: String, name: String)
  /// The song is present in the named playlist.
  case inPlaylist(playlistId: String, name: String)

  /// A stable identity for the *kind* of rule, used by the builder to decide
  /// which rule types may appear more than once (only the playlist-membership
  /// ones may) and to replace a rule in place when the user edits it.
  public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
    case addedWithinDays
    case played
    case playlistCount
    case notInPlaylist
    case inPlaylist

    /// Rule kinds that may legitimately appear several times in one query.
    /// The others are single-instance: a second `addedWithinDays` rule could
    /// only ever narrow or contradict the first.
    public var isRepeatable: Bool {
      switch self {
      case .inPlaylist, .notInPlaylist: return true
      case .addedWithinDays, .played, .playlistCount: return false
      }
    }

    public var displayName: String {
      switch self {
      case .addedWithinDays: return "Added to library"
      case .played: return "Play history"
      case .playlistCount: return "Playlist count"
      case .notInPlaylist: return "Not in playlist"
      case .inPlaylist: return "In playlist"
      }
    }
  }

  public var kind: Kind {
    switch self {
    case .addedWithinDays: return .addedWithinDays
    case .played: return .played
    case .playlistCount: return .playlistCount
    case .notInPlaylist: return .notInPlaylist
    case .inPlaylist: return .inPlaylist
    }
  }

  /// The playlist this rule targets, if it is a playlist-membership rule.
  public var referencedPlaylistId: String? {
    switch self {
    case let .inPlaylist(playlistId, _), let .notInPlaylist(playlistId, _):
      return playlistId
    case .addedWithinDays, .played, .playlistCount:
      return nil
    }
  }

  /// One-line human-readable rendering, used in the builder rows and in the
  /// query summary on the results screen.
  public var displayText: String {
    switch self {
    case let .addedWithinDays(days):
      return "Added in the last \(days) \(SmartPlaylistQuery.dayWord(days))"
    case let .played(playedRule):
      return playedRule.displayText
    case let .playlistCount(comparison, count):
      return "In \(comparison.displayText) \(count) \(count == 1 ? "playlist" : "playlists")"
    case let .notInPlaylist(_, name):
      return "Not in \"\(name)\""
    case let .inPlaylist(_, name):
      return "In \"\(name)\""
    }
  }
}

// MARK: - SmartPlaylistQuery

/// An AND-combined list of rules. V1 has no OR / nesting — "Match ALL of the
/// following" is the whole model, mirroring the simplest Apple Music smart
/// playlist form. Codable so the whole query round-trips through
/// `SmartPlaylistStore`.
public struct SmartPlaylistQuery: Codable, Equatable, Sendable {
  public var rules: [SmartPlaylistRule]

  public init(rules: [SmartPlaylistRule] = []) {
    self.rules = rules
  }

  public var isEmpty: Bool { rules.isEmpty }

  /// The active added-within-days window, if any. The refresher uses this to
  /// decide whether a newest-albums backfill is needed and where to stop
  /// paging. If several such rules somehow exist, the *widest* window wins so
  /// the backfill covers everything the query could possibly match.
  public var addedWithinDays: Int? {
    let windows = rules.compactMap { rule -> Int? in
      guard case let .addedWithinDays(days) = rule else { return nil }
      return days
    }
    return windows.max()
  }

  /// Whether any rule depends on playlist membership. Drives the
  /// "sync unsynced playlists first" step of an online refresh, because
  /// `PlaylistItemMO` rows only exist for individually fetched playlists.
  public var requiresPlaylistItems: Bool {
    rules.contains { rule in
      switch rule {
      case .inPlaylist, .notInPlaylist, .playlistCount: return true
      case .addedWithinDays, .played: return false
      }
    }
  }

  /// The ids of every playlist referenced by a membership rule.
  public var referencedPlaylistIds: [String] {
    rules.compactMap { $0.referencedPlaylistId }
  }

  /// Whether a rule of this kind can still be added (single-instance kinds are
  /// offered only while absent).
  public func canAddRule(ofKind kind: SmartPlaylistRule.Kind) -> Bool {
    kind.isRepeatable || !rules.contains { $0.kind == kind }
  }

  /// Multi-line-free summary used under the results header, e.g.
  /// `"Added in the last 30 days · Never played"`. Empty queries read as
  /// "All songs" because an empty rule list matches the whole library.
  public var summaryText: String {
    guard !rules.isEmpty else { return "All songs" }
    return rules.map { $0.displayText }.joined(separator: " · ")
  }

  static func dayWord(_ days: Int) -> String {
    days == 1 ? "day" : "days"
  }
}
