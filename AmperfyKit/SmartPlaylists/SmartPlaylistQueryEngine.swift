//
//  SmartPlaylistQueryEngine.swift
//  AmperfyKit
//
//  Fetch + evaluation for Smart Playlists
//  (V1 spec 2026-08-17, reworked for grouped AND/OR queries by the V1.5 addendum).
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
  /// Songs that would match the query if every `addedWithinDays` rule were
  /// treated as satisfied, but do not match as things stand — i.e. songs kept
  /// out *solely* because the library has no added-date for them.
  ///
  /// Defined over the whole tree, so a nil-date song that still qualifies
  /// through an OR branch is in `songs` and is NOT counted here.
  public let songsMissingAddedDate: Int
  /// Playlist rules whose playlist no longer exists locally. They were pruned
  /// from the evaluated tree (rather than matching nothing forever); the UI
  /// surfaces them so the user can repair the query.
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

/// Runs a `SmartPlaylistQuery` against the local library.
///
/// # Why the rules are no longer predicates
///
/// V1 ANDed one `NSPredicate` per rule into a single fetch. With the V1.5
/// grouped AND/OR model that is impossible: an OR branch cannot be ANDed into
/// the fetch, and `.playlistCount` was already a post-filter because
/// `SUBQUERY(...).@count` counts playlist *entries* rather than distinct
/// playlists (BUG-2, QA 2026-08-17).
///
/// So evaluation is now:
///
///  1. **One candidate fetch** carrying only the two always-on guards —
///     `SongMO.excludeServerDeleteUncachedSongsFetchPredicate` (never surface a
///     ghost row for a song deleted server-side and not cached) and account
///     scoping — sorted into final presentation order by the store.
///  2. **One `PlaylistItemMO` fetch** (only when a playlist rule is active)
///     folded into both the distinct-playlist-count map and the member-id sets
///     of the playlists the query names.
///  3. **One in-Swift boolean-tree pass per song** (`SmartPlaylistTreeEvaluator`),
///     which is a handful of field reads and hash lookups.
///
/// Two fetches total, whatever the query says, over a library of ~11k songs.
public enum SmartPlaylistQueryEngine {
  // MARK: - Evaluation

  /// Runs the query and returns the matched songs plus the caveats the results
  /// screen shows.
  public static func evaluate(
    query: SmartPlaylistQuery,
    context: NSManagedObjectContext,
    account: Account,
    now: Date = Date()
  )
    -> SmartPlaylistEvaluation {
    let existingPlaylistIds = fetchExistingUserPlaylistIds(context: context, account: account)
    let (prunedQuery, droppedPlaylistRules) = prune(
      query: query,
      existingPlaylistIds: existingPlaylistIds
    )

    let facts = makeFacts(query: prunedQuery, context: context, account: account, now: now)
    let candidateSongs = fetchCandidateSongs(
      query: prunedQuery,
      context: context,
      account: account
    )

    // Only worth running the second pass when a missing date can exclude at all.
    let hasAddedWithinRule = prunedQuery.addedWithinDays != nil

    var matchedSongs = [SongMO]()
    matchedSongs.reserveCapacity(candidateSongs.count)
    var songsMissingAddedDate = 0

    for songMO in candidateSongs {
      let songId = songMO.id
      if SmartPlaylistTreeEvaluator.matches(
        query: prunedQuery,
        songMO: songMO,
        songId: songId,
        facts: facts,
        treatAddedWithinAsSatisfied: false
      ) {
        matchedSongs.append(songMO)
        continue
      }
      guard hasAddedWithinRule, songMO.addedDate == nil else { continue }
      if SmartPlaylistTreeEvaluator.matches(
        query: prunedQuery,
        songMO: songMO,
        songId: songId,
        facts: facts,
        treatAddedWithinAsSatisfied: true
      ) {
        songsMissingAddedDate += 1
      }
    }

    return SmartPlaylistEvaluation(
      songs: matchedSongs,
      songsMissingAddedDate: songsMissingAddedDate,
      droppedPlaylistRules: droppedPlaylistRules
    )
  }

  // MARK: - Pruning

  /// Removes rules pointing at playlists that no longer exist and reports them.
  ///
  /// A vanished playlist must LOOSEN the query, never empty it: the rule is
  /// removed from its container, and a group left with no rules is removed from
  /// the top level (an empty OR group would otherwise evaluate to "nothing
  /// matches" and silently blank the whole result).
  static func prune(
    query: SmartPlaylistQuery,
    existingPlaylistIds: Set<String>
  )
    -> (query: SmartPlaylistQuery, droppedPlaylistRules: [SmartPlaylistRule]) {
    var droppedPlaylistRules = [SmartPlaylistRule]()

    func isResolvable(_ rule: SmartPlaylistRule) -> Bool {
      guard let referencedPlaylistId = rule.referencedPlaylistId else { return true }
      guard existingPlaylistIds.contains(referencedPlaylistId) else {
        droppedPlaylistRules.append(rule)
        return false
      }
      return true
    }

    var prunedItems = [SmartPlaylistQueryItem]()
    for item in query.items {
      switch item {
      case let .rule(rule):
        if isResolvable(rule) {
          prunedItems.append(.rule(rule))
        }
      case var .group(group):
        group.rules = group.rules.filter(isResolvable)
        if !group.rules.isEmpty {
          prunedItems.append(.group(group))
        }
      }
    }

    return (
      SmartPlaylistQuery(combinator: query.combinator, items: prunedItems),
      droppedPlaylistRules
    )
  }

  // MARK: - Candidate fetch

  /// Every song of the account that is allowed to be shown at all, already in
  /// presentation order (`addedDate` DESC, unknown last, then title).
  ///
  /// The `album` relationship is prefetched only when a `completeAlbum` rule
  /// will read it — over a whole library that prefetch is the difference
  /// between one extra batch fetch and none.
  static func fetchCandidateSongs(
    query: SmartPlaylistQuery,
    context: NSManagedObjectContext,
    account: Account
  )
    -> [SongMO] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: mandatoryPredicates(account: account)
    )
    fetchRequest.returnsObjectsAsFaults = false
    if query.requiresAlbumData {
      fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(SongMO.album)]
    }
    return (try? context.fetch(fetchRequest)) ?? []
  }

  // MARK: - Facts

  /// Builds the shared lookups from ONE `PlaylistItemMO` fetch — skipped
  /// entirely when the query asks nothing about playlists.
  static func makeFacts(
    query: SmartPlaylistQuery,
    context: NSManagedObjectContext,
    account: Account,
    now: Date
  )
    -> SmartPlaylistEvaluationFacts {
    guard query.requiresPlaylistItems else {
      return .empty(now: now)
    }

    let referencedPlaylistIds = Set(query.referencedPlaylistIds)
    let needsDistinctCounts = query.allRules.contains { $0.kind == .playlistCount }
    let playlistItems = fetchUserPlaylistItems(context: context, account: account)

    var playlistIdsBySongId = [String: Set<String>]()
    var memberSongIdsByPlaylistId = [String: Set<String>]()
    for playlistItem in playlistItems {
      let songId = playlistItem.playable.id
      let playlistId = playlistItem.playlist.id
      if needsDistinctCounts {
        playlistIdsBySongId[songId, default: []].insert(playlistId)
      }
      if referencedPlaylistIds.contains(playlistId) {
        memberSongIdsByPlaylistId[playlistId, default: []].insert(songId)
      }
    }
    // Named-but-empty playlists must still resolve to "nobody is a member".
    for referencedPlaylistId in referencedPlaylistIds
      where memberSongIdsByPlaylistId[referencedPlaylistId] == nil {
      memberSongIdsByPlaylistId[referencedPlaylistId] = []
    }

    return SmartPlaylistEvaluationFacts(
      now: now,
      distinctPlaylistCountsBySongId: playlistIdsBySongId.mapValues { $0.count },
      memberSongIdsByPlaylistId: memberSongIdsByPlaylistId
    )
  }

  /// Playlist entries in REAL user playlists owned by `account`.
  ///
  /// "Real user playlist" matches `RecentTracksQuery.songNotInAnyUserPlaylist`:
  /// smart playlists (`smart_` id prefix, server-side Ampache rules) and
  /// unnamed playlists (the Player's internal context/queue/podcast/shuffled
  /// lists) are excluded, and membership is scoped through the **playlist's**
  /// account rather than the item's — an item's account is copied from its
  /// playable, so it cannot tell whose playlist the song actually sits in.
  static func fetchUserPlaylistItems(
    context: NSManagedObjectContext,
    account: Account
  )
    -> [PlaylistItemMO] {
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
    return (try? context.fetch(fetchRequest)) ?? []
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
