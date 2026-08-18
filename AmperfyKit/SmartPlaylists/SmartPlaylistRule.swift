//
//  SmartPlaylistRule.swift
//  AmperfyKit
//
//  The leaf of a smart playlist query — one condition a song is checked against
//  (V1 spec 2026-08-17, V1.5 addendum: `completeAlbum`).
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

/// One condition of a smart playlist query. Rules are combined by their
/// containing level's `SmartPlaylistCombinator` (see `SmartPlaylistQuery`).
///
/// Playlist rules carry the playlist's *display name* alongside its id so the
/// builder and the query summary render correctly offline. The name is a
/// snapshot for display only — evaluation always resolves by id, and a rule
/// whose playlist has vanished is dropped at evaluation time (and reported back
/// so the UI can flag it).
///
/// ⚠️ **Codable stability.** The synthesised representation of every case below
/// is persisted in `SmartPlaylistStore`. Cases may be *added* (old blobs keep
/// decoding, which is how `completeAlbum` shipped in V1.5), but an existing
/// case's name or associated-value labels must never change without a
/// migration.
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
  /// The song's parent album is (or is not) a *whole* album per
  /// `WholeAlbumPredicates` with `minSongCount == 3` — the same definition the
  /// Albums view's "complete albums only" toggle uses. See
  /// `SmartPlaylistRuleEvaluator.isPartOfCompleteAlbum`.
  case completeAlbum(isComplete: Bool)

  /// A stable identity for the *kind* of rule, used by the builder to decide
  /// which rule types may appear more than once (only the playlist-membership
  /// ones may) and to replace a rule in place when the user edits it.
  public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
    case addedWithinDays
    case played
    case playlistCount
    case notInPlaylist
    case inPlaylist
    case completeAlbum

    /// Rule kinds that may legitimately appear several times in one container.
    /// The others are single-instance *per container*: a second
    /// `addedWithinDays` rule in the same AND level could only ever narrow or
    /// contradict the first. Groups are separate containers, so
    /// "is complete OR added in the last 7 days" style branches stay
    /// expressible.
    public var isRepeatable: Bool {
      switch self {
      case .inPlaylist, .notInPlaylist: return true
      case .addedWithinDays, .completeAlbum, .played, .playlistCount: return false
      }
    }

    public var displayName: String {
      switch self {
      case .addedWithinDays: return "Added to library"
      case .played: return "Play history"
      case .playlistCount: return "Playlist count"
      case .notInPlaylist: return "Not in playlist"
      case .inPlaylist: return "In playlist"
      case .completeAlbum: return "Complete album"
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
    case .completeAlbum: return .completeAlbum
    }
  }

  /// The playlist this rule targets, if it is a playlist-membership rule.
  public var referencedPlaylistId: String? {
    switch self {
    case let .inPlaylist(playlistId, _), let .notInPlaylist(playlistId, _):
      return playlistId
    case .addedWithinDays, .completeAlbum, .played, .playlistCount:
      return nil
    }
  }

  /// Whether answering this rule needs `PlaylistItemMO` rows to exist locally.
  /// Drives the refresher's "sync unsynced playlists first" step.
  public var requiresPlaylistItems: Bool {
    switch self {
    case .inPlaylist, .notInPlaylist, .playlistCount: return true
    case .addedWithinDays, .completeAlbum, .played: return false
    }
  }

  /// Whether answering this rule needs the song's `album` relationship, so the
  /// evaluation fetch can prefetch it only when it will actually be read.
  public var requiresAlbumData: Bool {
    kind == .completeAlbum
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
    case let .completeAlbum(isComplete):
      return isComplete ? "Part of a complete album" : "Not part of a complete album"
    }
  }
}
