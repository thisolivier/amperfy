//
//  SmartPlaylistQueryEngine.swift
//  AmperfyKit
//
//  Predicate construction + evaluation for Smart Playlists (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistEvaluation

/// Everything one evaluation pass produced: the matched songs (already in
/// presentation order) plus the two facts the results screen needs to explain
/// itself honestly.
public struct SmartPlaylistEvaluation {
  /// Matched songs, `addedDate` DESC (unknown dates last), then title.
  public let songs: [SongMO]
  /// How many songs would otherwise have been candidates but carry no
  /// `addedDate` yet. Zero unless the query has an `addedWithinDays` rule —
  /// only then does a missing date silently exclude a song.
  public let songsMissingAddedDate: Int
  /// Playlist rules whose playlist no longer exists locally. They were dropped
  /// from the evaluated predicate (rather than matching nothing forever); the
  /// UI surfaces them so the user can repair the query.
  public let droppedPlaylistRules: [SmartPlaylistRule]

  public init(
    songs: [SongMO],
    songsMissingAddedDate: Int,
    droppedPlaylistRules: [SmartPlaylistRule]
  ) {
    self.songs = songs
    self.songsMissingAddedDate = songsMissingAddedDate
    self.droppedPlaylistRules = droppedPlaylistRules
  }
}

// MARK: - SmartPlaylistQueryEngine

/// Translates a `SmartPlaylistQuery` into a single compound `NSPredicate` and
/// runs it as ONE Core Data fetch — no per-song loops, no in-memory filtering.
/// Playlist-membership rules are expressed as `SUBQUERY` counts over the song's
/// own inverse `playlistItems` relationship, exactly as
/// `RecentTracksQuery.songNotInAnyUserPlaylist` does.
///
/// Two guards are ALWAYS ANDed in, whatever the query says:
///
///  * `SongMO.excludeServerDeleteUncachedSongsFetchPredicate` — never surface a
///    ghost row for a song deleted server-side and not cached locally.
///  * account scoping — a smart playlist belongs to the account that built it.
public enum SmartPlaylistQueryEngine {
  // MARK: - Membership sub-predicates

  /// Count of *playlist entries* in real user playlists owned by `account`.
  ///
  /// "Real user playlist" matches `RecentTracksQuery.songNotInAnyUserPlaylist`:
  /// smart playlists (`smart_` id prefix, server-side Ampache rules) and
  /// unnamed playlists (the Player's internal context/queue/podcast/shuffled
  /// lists) are excluded, and membership is scoped through the **playlist's**
  /// account rather than the item's — an item's account is copied from its
  /// playable, so it cannot tell whose playlist the song actually sits in.
  ///
  /// ⚠️ This counts ENTRIES, not distinct playlists: a song listed twice in one
  /// playlist counts as 2 here (QA 2026-08-17 — "fewer than 2 playlists" dropped
  /// a song that sat twice in a single playlist). `SUBQUERY(...).@count` has no
  /// distinct form that survives translation to the SQLite store, so `evaluate`
  /// no longer uses this predicate for `.playlistCount` rules — it applies
  /// `distinctUserPlaylistCountsBySongId` in Swift instead. Kept public because
  /// it is still the honest expression of "how many entries" and callers may
  /// want it for inspection, but do NOT use it to answer a distinct-playlist
  /// question.
  public static func userPlaylistCountPredicate(
    comparison: SmartPlaylistCountComparison,
    count: Int,
    account: Account
  )
    -> NSPredicate {
    let comparisonOperator = comparison == .fewerThan ? "<" : ">"
    return NSPredicate(
      format: """
      SUBQUERY(playlistItems, $item, \
      $item.playlist.account == %@ \
      AND NOT ($item.playlist.id BEGINSWITH %@) \
      AND $item.playlist.name != nil AND $item.playlist.name != %@) \
      .@count \(comparisonOperator) %d
      """,
      account.managedObject.objectID,
      Playlist.smartPlaylistIdPrefix,
      "",
      count
    )
  }

  /// Membership in ONE specific playlist, resolved by id. `isMember == false`
  /// yields the "not in playlist" form. Account scoping still runs through the
  /// playlist relationship so an id collision across accounts cannot leak.
  public static func specificPlaylistPredicate(
    playlistId: String,
    isMember: Bool,
    account: Account
  )
    -> NSPredicate {
    let comparison = isMember ? "> 0" : "== 0"
    return NSPredicate(
      format: """
      SUBQUERY(playlistItems, $item, \
      $item.playlist.account == %@ \
      AND $item.playlist.id == %@) \
      .@count \(comparison)
      """,
      account.managedObject.objectID,
      playlistId
    )
  }

  // MARK: - Per-rule predicates

  /// Builds the predicate for one rule, or `nil` when the rule cannot be
  /// evaluated (its playlist vanished) and must be dropped.
  ///
  /// `existingPlaylistIds` is the set of playlist ids that currently exist for
  /// the account; pass `nil` to skip the existence check entirely (useful when
  /// building a predicate for inspection rather than for a live fetch).
  ///
  /// `.playlistCount` is the one rule `evaluate` does NOT take from here: the
  /// predicate it returns counts playlist entries, and the rule means distinct
  /// playlists (see `userPlaylistCountPredicate`). Evaluation resolves it with
  /// an exact in-Swift pass.
  public static func predicate(
    for rule: SmartPlaylistRule,
    account: Account,
    now: Date,
    existingPlaylistIds: Set<String>?
  )
    -> NSPredicate? {
    switch rule {
    case let .addedWithinDays(days):
      return NSPredicate(
        format: "%K >= %@",
        #keyPath(SongMO.addedDate),
        cutoffDate(daysAgo: days, from: now) as NSDate
      )

    case let .played(playedRule):
      switch playedRule {
      case .never:
        return NSPredicate(format: "%K == 0", #keyPath(SongMO.playCount))
      case let .notInLastDays(days):
        // A song never played at all satisfies "not played in the last N days".
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSPredicate(format: "%K == nil", #keyPath(SongMO.lastPlayedDate)),
          NSPredicate(
            format: "%K < %@",
            #keyPath(SongMO.lastPlayedDate),
            cutoffDate(daysAgo: days, from: now) as NSDate
          ),
        ])
      case let .inLastDays(days):
        return NSPredicate(
          format: "%K >= %@",
          #keyPath(SongMO.lastPlayedDate),
          cutoffDate(daysAgo: days, from: now) as NSDate
        )
      }

    case let .playlistCount(comparison, count):
      return userPlaylistCountPredicate(
        comparison: comparison,
        count: count,
        account: account
      )

    case let .notInPlaylist(playlistId, _):
      guard playlistExists(playlistId, in: existingPlaylistIds) else { return nil }
      return specificPlaylistPredicate(
        playlistId: playlistId,
        isMember: false,
        account: account
      )

    case let .inPlaylist(playlistId, _):
      guard playlistExists(playlistId, in: existingPlaylistIds) else { return nil }
      return specificPlaylistPredicate(
        playlistId: playlistId,
        isMember: true,
        account: account
      )
    }
  }

  // MARK: - Evaluation

  /// Runs the query. One fetch for the result set; one extra `count` fetch —
  /// only when an `addedWithinDays` rule is active — for the
  /// "N songs have no added-date yet" footer; and one extra playlist-item fetch
  /// — only when a `.playlistCount` rule is active — for the distinct-playlist
  /// counts that rule needs (Core Data cannot express them as a predicate).
  public static func evaluate(
    query: SmartPlaylistQuery,
    context: NSManagedObjectContext,
    account: Account,
    now: Date = Date()
  )
    -> SmartPlaylistEvaluation {
    let existingPlaylistIds = fetchExistingUserPlaylistIds(context: context, account: account)

    var rulePredicates = [NSPredicate]()
    var droppedPlaylistRules = [SmartPlaylistRule]()
    var playlistCountRules = [SmartPlaylistRule]()
    for rule in query.rules {
      // Counting rules are resolved after the fetch, against distinct playlists.
      guard rule.kind != .playlistCount else {
        playlistCountRules.append(rule)
        continue
      }
      if let rulePredicate = predicate(
        for: rule,
        account: account,
        now: now,
        existingPlaylistIds: existingPlaylistIds
      ) {
        rulePredicates.append(rulePredicate)
      } else {
        droppedPlaylistRules.append(rule)
      }
    }

    let distinctPlaylistCountsBySongId = playlistCountRules.isEmpty
      ? nil
      : distinctUserPlaylistCountsBySongId(context: context, account: account)

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: mandatoryPredicates(account: account) + rulePredicates
    )
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    var songs = (try? context.fetch(fetchRequest)) ?? []
    if let distinctPlaylistCountsBySongId {
      songs = songs.filter { song in
        songSatisfies(
          playlistCountRules: playlistCountRules,
          distinctPlaylistCount: distinctPlaylistCountsBySongId[song.id] ?? 0
        )
      }
    }

    let songsMissingAddedDate = countSongsMissingAddedDate(
      query: query,
      context: context,
      account: account,
      now: now,
      existingPlaylistIds: existingPlaylistIds,
      distinctPlaylistCountsBySongId: distinctPlaylistCountsBySongId
    )

    return SmartPlaylistEvaluation(
      songs: songs,
      songsMissingAddedDate: songsMissingAddedDate,
      droppedPlaylistRules: droppedPlaylistRules
    )
  }

  /// How many songs pass every rule EXCEPT the added-within-days window purely
  /// because their `addedDate` is unknown. This is the honest denominator for
  /// the footer note: these songs are neither in nor out — the library simply
  /// does not know when they arrived (see `ADDED_DATE_INVESTIGATION.md`; bulk
  /// album sync never populated `addedDate`).
  ///
  /// Returns 0 when the query has no `addedWithinDays` rule, because then a
  /// missing date excludes nothing and the note would be noise.
  ///
  /// `distinctPlaylistCountsBySongId` is the map `evaluate` already built when
  /// the query has a `.playlistCount` rule; passing it keeps this count on the
  /// same footing as the result set (a cheap `count` fetch cannot honour a rule
  /// that is resolved in Swift, so the fetch is materialised instead — only in
  /// that case).
  static func countSongsMissingAddedDate(
    query: SmartPlaylistQuery,
    context: NSManagedObjectContext,
    account: Account,
    now: Date,
    existingPlaylistIds: Set<String>?,
    distinctPlaylistCountsBySongId: [String: Int]? = nil
  )
    -> Int {
    guard query.addedWithinDays != nil else { return 0 }

    let otherRules = query.rules.filter { $0.kind != .addedWithinDays }
    let playlistCountRules = otherRules.filter { $0.kind == .playlistCount }
    let otherRulePredicates = otherRules
      .filter { $0.kind != .playlistCount }
      .compactMap {
        predicate(for: $0, account: account, now: now, existingPlaylistIds: existingPlaylistIds)
      }

    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: mandatoryPredicates(account: account)
        + otherRulePredicates
        + [NSPredicate(format: "%K == nil", #keyPath(SongMO.addedDate))]
    )
    guard !playlistCountRules.isEmpty else {
      return (try? context.count(for: fetchRequest)) ?? 0
    }

    let distinctCounts = distinctPlaylistCountsBySongId
      ?? distinctUserPlaylistCountsBySongId(context: context, account: account)
    let candidateSongs = (try? context.fetch(fetchRequest)) ?? []
    return candidateSongs.filter { song in
      songSatisfies(
        playlistCountRules: playlistCountRules,
        distinctPlaylistCount: distinctCounts[song.id] ?? 0
      )
    }.count
  }

  // MARK: - Distinct playlist counts

  /// `songId → number of DISTINCT real user playlists the song sits in`.
  ///
  /// Built from one fetch over `PlaylistItemMO` because a song can legitimately
  /// appear twice in the same playlist, and `SUBQUERY(...).@count` would then
  /// report two playlists (BUG-2, QA 2026-08-17). Core Data has no distinct
  /// aggregate that survives translation to the SQLite store, so the fold
  /// happens here — once per evaluation, not once per song.
  ///
  /// The membership scoping is deliberately identical to
  /// `userPlaylistCountPredicate`: the playlist's account, no `smart_` ids, no
  /// unnamed system playlists. Songs absent from the map sit in zero playlists.
  static func distinctUserPlaylistCountsBySongId(
    context: NSManagedObjectContext,
    account: Account
  )
    -> [String: Int] {
    let fetchRequest: NSFetchRequest<PlaylistItemMO> = PlaylistItemMO.fetchRequest()
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "%K != nil", #keyPath(PlaylistItemMO.playable)),
      NSPredicate(
        format: "%K == %@",
        #keyPath(PlaylistItemMO.playlist.account),
        account.managedObject.objectID
      ),
      NSPredicate(
        format: "NOT (%K BEGINSWITH %@)",
        #keyPath(PlaylistItemMO.playlist.id),
        Playlist.smartPlaylistIdPrefix
      ),
      NSPredicate(
        format: "%K != nil AND %K != %@",
        #keyPath(PlaylistItemMO.playlist.name),
        #keyPath(PlaylistItemMO.playlist.name),
        ""
      ),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = [
      #keyPath(PlaylistItemMO.playable),
      #keyPath(PlaylistItemMO.playlist),
    ]
    let playlistItems = (try? context.fetch(fetchRequest)) ?? []

    var playlistIdsBySongId = [String: Set<String>]()
    for playlistItem in playlistItems {
      playlistIdsBySongId[playlistItem.playable.id, default: []].insert(playlistItem.playlist.id)
    }
    return playlistIdsBySongId.mapValues { $0.count }
  }

  /// Whether a song sitting in `distinctPlaylistCount` playlists passes every
  /// `.playlistCount` rule in the list. Non-count rules are ignored, so callers
  /// can hand over a pre-filtered slice without re-checking the kind.
  static func songSatisfies(
    playlistCountRules: [SmartPlaylistRule],
    distinctPlaylistCount: Int
  )
    -> Bool {
    playlistCountRules.allSatisfy { rule in
      guard case let .playlistCount(comparison, count) = rule else { return true }
      switch comparison {
      case .fewerThan: return distinctPlaylistCount < count
      case .moreThan: return distinctPlaylistCount > count
      }
    }
  }

  // MARK: - Helpers

  /// The guards every smart playlist fetch carries regardless of its rules.
  static func mandatoryPredicates(account: Account) -> [NSPredicate] {
    [
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      NSPredicate(format: "account == %@", account.managedObject.objectID),
    ]
  }

  static func cutoffDate(daysAgo days: Int, from now: Date) -> Date {
    now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
  }

  private static func playlistExists(_ playlistId: String, in knownIds: Set<String>?) -> Bool {
    guard let knownIds else { return true }
    return knownIds.contains(playlistId)
  }

  /// Ids of the account's real user playlists (non-smart, named) — used only to
  /// decide whether a playlist rule still resolves.
  static func fetchExistingUserPlaylistIds(
    context: NSManagedObjectContext,
    account: Account
  )
    -> Set<String> {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "account == %@", account.managedObject.objectID),
      NSPredicate(
        format: "NOT (%K BEGINSWITH %@)",
        #keyPath(PlaylistMO.id),
        Playlist.smartPlaylistIdPrefix
      ),
      NSPredicate(
        format: "%K != nil AND %K != %@",
        #keyPath(PlaylistMO.name),
        #keyPath(PlaylistMO.name),
        ""
      ),
    ])
    let playlists = (try? context.fetch(fetchRequest)) ?? []
    return Set(playlists.map { $0.id })
  }
}
