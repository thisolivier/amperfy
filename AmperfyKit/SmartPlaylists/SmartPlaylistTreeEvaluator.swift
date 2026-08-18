//
//  SmartPlaylistTreeEvaluator.swift
//  AmperfyKit
//
//  Per-song, in-memory evaluation of a grouped smart playlist query
//  (V1.5 addendum §1/§2).
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

// MARK: - SmartPlaylistEvaluationFacts

/// The lookups every per-song check shares, built ONCE per evaluation.
///
/// With OR in the model no rule can be pushed into the fetch predicate any
/// more (an OR branch cannot be ANDed in), so every rule is answered here in
/// Swift. Everything that would otherwise need a per-song query is precomputed
/// into a dictionary so the per-song cost stays a hash lookup.
struct SmartPlaylistEvaluationFacts {
  /// Injected clock — every relative-date rule measures from here.
  let now: Date
  /// `songId → number of DISTINCT real user playlists the song sits in`.
  /// Empty when no `.playlistCount` rule is active.
  let distinctPlaylistCountsBySongId: [String: Int]
  /// `playlistId → ids of the songs in it`, built only for the playlists the
  /// query actually names.
  let memberSongIdsByPlaylistId: [String: Set<String>]

  static func empty(now: Date) -> Self {
    SmartPlaylistEvaluationFacts(
      now: now,
      distinctPlaylistCountsBySongId: [:],
      memberSongIdsByPlaylistId: [:]
    )
  }
}

// MARK: - SmartPlaylistTreeEvaluator

/// Evaluates a (already pruned) query tree against one song.
///
/// `treatAddedWithinAsSatisfied` is the lever behind
/// `SmartPlaylistEvaluation.songsMissingAddedDate`: running the same tree twice,
/// once honestly and once with every `addedWithinDays` rule forced true, isolates
/// exactly the songs that are excluded *solely* because the library does not know
/// when they arrived — including songs that would have qualified through an OR
/// branch, which a naive "count the nil dates" pass would over-report.
enum SmartPlaylistTreeEvaluator {
  /// The whole top-level container. An empty container matches everything: a
  /// query with no rules means "all songs", and a level emptied by rule pruning
  /// must loosen the query, never silently empty it.
  static func matches(
    query: SmartPlaylistQuery,
    songMO: SongMO,
    songId: String,
    facts: SmartPlaylistEvaluationFacts,
    treatAddedWithinAsSatisfied: Bool
  )
    -> Bool {
    guard !query.items.isEmpty else { return true }
    switch query.combinator {
    case .all:
      for item in query.items
        where !matches(
          item: item,
          songMO: songMO,
          songId: songId,
          facts: facts,
          treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
        ) {
        return false
      }
      return true
    case .any:
      for item in query.items
        where matches(
          item: item,
          songMO: songMO,
          songId: songId,
          facts: facts,
          treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
        ) {
        return true
      }
      return false
    }
  }

  static func matches(
    item: SmartPlaylistQueryItem,
    songMO: SongMO,
    songId: String,
    facts: SmartPlaylistEvaluationFacts,
    treatAddedWithinAsSatisfied: Bool
  )
    -> Bool {
    switch item {
    case let .rule(rule):
      return matches(
        rule: rule,
        songMO: songMO,
        songId: songId,
        facts: facts,
        treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
      )
    case let .group(group):
      return matches(
        group: group,
        songMO: songMO,
        songId: songId,
        facts: facts,
        treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
      )
    }
  }

  /// A group of one rule is legal and behaves exactly like the bare rule. An
  /// empty group matches everything, for the same reason an empty top level
  /// does — but the caller prunes those away before we get here.
  static func matches(
    group: SmartPlaylistRuleGroup,
    songMO: SongMO,
    songId: String,
    facts: SmartPlaylistEvaluationFacts,
    treatAddedWithinAsSatisfied: Bool
  )
    -> Bool {
    guard !group.rules.isEmpty else { return true }
    switch group.combinator {
    case .all:
      for rule in group.rules
        where !matches(
          rule: rule,
          songMO: songMO,
          songId: songId,
          facts: facts,
          treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
        ) {
        return false
      }
      return true
    case .any:
      for rule in group.rules
        where matches(
          rule: rule,
          songMO: songMO,
          songId: songId,
          facts: facts,
          treatAddedWithinAsSatisfied: treatAddedWithinAsSatisfied
        ) {
        return true
      }
      return false
    }
  }

  // MARK: - Leaf

  static func matches(
    rule: SmartPlaylistRule,
    songMO: SongMO,
    songId: String,
    facts: SmartPlaylistEvaluationFacts,
    treatAddedWithinAsSatisfied: Bool
  )
    -> Bool {
    switch rule {
    case let .addedWithinDays(days):
      guard !treatAddedWithinAsSatisfied else { return true }
      guard let addedDate = songMO.addedDate else { return false }
      return addedDate >= SmartPlaylistQueryEngine.cutoffDate(daysAgo: days, from: facts.now)

    case let .played(playedRule):
      switch playedRule {
      case .never:
        return songMO.playCount == 0
      case let .notInLastDays(days):
        // A song never played at all satisfies "not played in the last N days".
        guard let lastPlayedDate = songMO.lastPlayedDate else { return true }
        return lastPlayedDate < SmartPlaylistQueryEngine.cutoffDate(
          daysAgo: days,
          from: facts.now
        )
      case let .inLastDays(days):
        guard let lastPlayedDate = songMO.lastPlayedDate else { return false }
        return lastPlayedDate >= SmartPlaylistQueryEngine.cutoffDate(
          daysAgo: days,
          from: facts.now
        )
      }

    case let .playlistCount(comparison, count):
      let distinctPlaylistCount = facts.distinctPlaylistCountsBySongId[songId] ?? 0
      switch comparison {
      case .fewerThan: return distinctPlaylistCount < count
      case .moreThan: return distinctPlaylistCount > count
      }

    case let .inPlaylist(playlistId, _):
      return facts.memberSongIdsByPlaylistId[playlistId]?.contains(songId) ?? false

    case let .notInPlaylist(playlistId, _):
      return !(facts.memberSongIdsByPlaylistId[playlistId]?.contains(songId) ?? false)

    case let .completeAlbum(isComplete):
      return isPartOfCompleteAlbum(songMO: songMO) == isComplete
    }
  }

  // MARK: - Complete album

  /// The song count at which a release stops being "a bag of singles" — the
  /// same threshold the Albums view's "complete albums only" toggle uses.
  static let completeAlbumMinSongCount: Int16 = 3

  /// Swift mirror of `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)`, lifted
  /// through the song's `album` relationship.
  ///
  /// The semantics are replicated EXACTLY, including the NULL handling the
  /// predicate goes out of its way to get right:
  ///
  ///  * a `releaseType` containing `"single"` (case-insensitive substring)
  ///    vetoes, however many tracks the release has;
  ///  * otherwise the verdict is `remoteSongCount >= 3` alone — a nil
  ///    `releaseType` is classified purely by count, never excluded for lacking
  ///    metadata (`getAlbumList2` usually omits `releaseTypes` entirely);
  ///  * a song with **no** album is NOT part of a complete album.
  static func isPartOfCompleteAlbum(songMO: SongMO) -> Bool {
    guard let albumMO = songMO.album else { return false }
    if let releaseType = albumMO.releaseType,
       releaseType.range(of: "single", options: .caseInsensitive) != nil {
      return false
    }
    return albumMO.remoteSongCount >= completeAlbumMinSongCount
  }
}
