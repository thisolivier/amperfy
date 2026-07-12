//
//  RecentTracksQuery.swift
//  AmperfyKit
//
//  Created by implementer-amperfy on 2026-04-11.
//  Copyright (c) 2026 Amperfy. All rights reserved.
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

/// Query helpers for the "recently added tracks" home widget and its
/// synthetic detail view.
///
/// All queries:
///
/// 1. Apply the standard "song must be playable" guard
///    (`SongMO.excludeServerDeleteUncachedSongsFetchPredicate`) so the
///    widget never surfaces ghost rows for songs whose backing files have
///    been removed server-side without a local cache.
/// 2. Sort by `addedDate` descending (most recent first).
///
/// `topN`, `lastMDays`, and `lastMDaysCount` additionally filter to songs
/// whose parent album is **not** a whole album, using
/// `WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 5)`. The
/// threshold is **5** here, intentionally stricter than the library-side
/// `wholeAlbum` filter (threshold 3) — false positives in the recent
/// tracks list are more annoying than false negatives in the Albums
/// filter. See `spike/amperfy/BACKLOG.md` §1.1 + §4.
///
/// This whole-album exclusion is deliberate, not a gap to be patched: the
/// recent-tracks widget is meant to surface individually-added / single-ish
/// tracks, and works in concert with the separate recent-albums section,
/// which already covers whole albums. A library whose recent additions are
/// entirely whole albums should show an empty (but visible) widget — do not
/// "fix" that by padding the result with whole-album tracks. (User-confirmed
/// design, sprint Amp-2, 2026-07.)
///
/// The entry points return raw `SongMO` arrays. Callers wrap them into
/// `Song` entity wrappers (the wrapping is left to the caller to keep this
/// helper free of presentation concerns and easier to unit-test).
public enum RecentTracksQuery {
  /// The non-whole-album threshold used by the recent-tracks widget. Singles
  /// and bags-of-singles below this track count are surfaced; anything at or
  /// above is treated as a whole album and excluded.
  public static let nonWholeAlbumMinSongCount: Int16 = 5

  /// Predicate over `Song` (`SongMO`) that matches songs which are **not** yet
  /// filed into any *real user* playlist owned by `account` — i.e. the song's
  /// triage state is "unfiled". Backs the Recently Added "Hide tracks already
  /// in playlists" toggle (the user's triage inbox: a track disappears from
  /// the list once it has been dropped into at least one playlist).
  ///
  /// The check runs entirely at the fetch level via a `SUBQUERY` over the
  /// song's own inverse `playlistItems` relationship (defined on
  /// `AbstractPlayableMO`), so no thousands-of-rows in-memory post-filter is
  /// needed.
  ///
  /// "Real user playlist" mirrors `PlaylistMembershipQuery.playlistsContaining`:
  ///
  ///   * **Smart playlists are excluded** (`NOT id BEGINSWITH "smart_"`) — they
  ///     are derived rules, not membership the user actively curated, so a song
  ///     matched only by a smart playlist is still "unfiled" for triage.
  ///   * **Unnamed / empty-name playlists are excluded** — this also filters
  ///     out the Player's internal system playlists (context/queue/podcast/
  ///     shuffled), which carry no user-facing name. The Recently Added listing
  ///     itself is *not* backed by any playlist (it is pure-query), so there is
  ///     nothing further to exclude on that account.
  ///   * **Membership is scoped to the active `account`** via the
  ///     **playlist's** `account` relationship (`$item.playlist.account`), so
  ///     a song filed only into a playlist owned by another account never hides
  ///     it here. (Scoping on `PlaylistItem.account` would be wrong: an item's
  ///     account is copied from its *playable*, not its playlist — see
  ///     `LibraryStorage.createPlaylistItem` — so it cannot distinguish which
  ///     account's playlist the song actually lives in.)
  public static func songNotInAnyUserPlaylist(account: Account) -> NSPredicate {
    NSPredicate(
      format: """
      SUBQUERY(playlistItems, $item, \
      $item.playlist.account == %@ \
      AND NOT ($item.playlist.id BEGINSWITH %@) \
      AND $item.playlist.name != nil AND $item.playlist.name != %@) \
      .@count == 0
      """,
      account.managedObject.objectID,
      Playlist.smartPlaylistIdPrefix,
      ""
    )
  }

  /// Combines the mandatory recent-tracks guards (non-whole-album + playable)
  /// with the optional "hide songs already filed into a playlist" guard.
  /// Callers pass `hideSongsInPlaylists` from the persisted toggle and the
  /// active `account`; when the toggle is off the membership predicate is
  /// simply omitted.
  private static func basePredicates(
    hideSongsInPlaylists: Bool,
    account: Account
  )
    -> [NSPredicate] {
    var predicates: [NSPredicate] = [
      // Deliberately excludes tracks belonging to whole albums: this widget
      // surfaces individually-added / single-ish tracks and works in
      // concert with the recent-albums section, which covers whole albums.
      // Do not "fix" an empty result by padding with album tracks — an
      // empty (but visible) widget is correct for libraries whose recent
      // additions are all whole albums. (User-confirmed design, sprint
      // Amp-2, 2026-07.)
      WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: nonWholeAlbumMinSongCount),
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
    ]
    if hideSongsInPlaylists {
      predicates.append(songNotInAnyUserPlaylist(account: account))
    }
    return predicates
  }

  /// Returns up to `n` songs sorted by `addedDate` DESC, filtered to songs
  /// whose parent album is not a whole album. This highlights
  /// individually-added tracks first; a library whose recent additions are
  /// all whole albums can legitimately (and correctly) return zero rows
  /// here — see the whole-album exclusion note in the file-level doc
  /// comment above. Used by:
  ///
  /// * The home widget (`HomeManager.updateRecentTracks()`), directly and
  ///   unpadded.
  /// * The synthetic detail view's "Top N" mode (default n=14).
  public static func topN(
    context: NSManagedObjectContext,
    n: Int,
    hideSongsInPlaylists: Bool,
    account: Account
  )
    -> [SongMO] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.fetchLimit = n
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: basePredicates(
        hideSongsInPlaylists: hideSongsInPlaylists,
        account: account
      )
    )
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    return (try? context.fetch(fetchRequest)) ?? []
  }

  /// Returns all songs added within the last `m` days (inclusive of the
  /// instant `now - m.days`), sorted by `addedDate` DESC, filtered to songs
  /// whose parent album is not a whole album. Used by:
  ///
  /// * The synthetic detail view's "Last M days" mode (default m=7).
  /// * The home widget's footer-count helper (
  ///   see `lastMDaysCount(context:m:)`).
  ///
  /// No fetch limit is applied — if the user asks for "last 30 days" we
  /// return all qualifying rows.
  public static func lastMDays(
    context: NSManagedObjectContext,
    m: Int,
    hideSongsInPlaylists: Bool,
    account: Account,
    now: Date = Date()
  )
    -> [SongMO] {
    let cutoff = now.addingTimeInterval(-Double(m) * 24 * 60 * 60)
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: basePredicates(
        hideSongsInPlaylists: hideSongsInPlaylists,
        account: account
      ) + [
        NSPredicate(format: "%K >= %@", #keyPath(SongMO.addedDate), cutoff as NSDate),
      ]
    )
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    return (try? context.fetch(fetchRequest)) ?? []
  }

  /// Returns the count of songs added within the last `m` days that pass the
  /// non-whole-album filter. Used by the home widget footer to render
  /// "(X more in the last 7 days)" without materialising the full result set.
  public static func lastMDaysCount(
    context: NSManagedObjectContext,
    m: Int,
    hideSongsInPlaylists: Bool,
    account: Account,
    now: Date = Date()
  )
    -> Int {
    let cutoff = now.addingTimeInterval(-Double(m) * 24 * 60 * 60)
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: basePredicates(
        hideSongsInPlaylists: hideSongsInPlaylists,
        account: account
      ) + [
        NSPredicate(format: "%K >= %@", #keyPath(SongMO.addedDate), cutoff as NSDate),
      ]
    )
    return (try? context.count(for: fetchRequest)) ?? 0
  }
}
