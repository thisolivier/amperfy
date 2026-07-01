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
/// 1. Filter to songs whose parent album is **not** a whole album, using
///    `WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 5)`. The
///    threshold is **5** here, intentionally stricter than the library-side
///    `wholeAlbum` filter (threshold 3) — false positives in the recent
///    tracks list are more annoying than false negatives in the Albums
///    filter. See `spike/amperfy/BACKLOG.md` §1.1 + §4.
/// 2. Apply the standard "song must be playable" guard
///    (`SongMO.excludeServerDeleteUncachedSongsFetchPredicate`) so the
///    widget never surfaces ghost rows for songs whose backing files have
///    been removed server-side without a local cache.
/// 3. Sort by `addedDate` descending (most recent first).
///
/// The two entry points return raw `SongMO` arrays. Callers wrap them into
/// `Song` entity wrappers (the wrapping is left to the caller to keep this
/// helper free of presentation concerns and easier to unit-test).
public enum RecentTracksQuery {
  /// The non-whole-album threshold used by the recent-tracks widget. Singles
  /// and bags-of-singles below this track count are surfaced; anything at or
  /// above is treated as a whole album and excluded.
  public static let nonWholeAlbumMinSongCount: Int16 = 5

  /// Returns up to `n` songs sorted by `addedDate` DESC, filtered to songs
  /// whose parent album is not a whole album. Used by:
  ///
  /// * The home widget (n=10) — bounded list. Once the widget is on the
  ///   home screen it always renders: Core Data's `fetchLimit` only caps
  ///   the result, it never pads, so this single fetch naturally covers
  ///   "fewer than 10 fresh songs" (falls back to older songs) and
  ///   "fewer than 10 songs in the whole library" (returns all of them)
  ///   with no extra merge/top-up logic required.
  /// * The synthetic detail view's "Top N" mode (default n=14).
  public static func topN(
    context: NSManagedObjectContext,
    n: Int
  )
    -> [SongMO] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.fetchLimit = n
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: nonWholeAlbumMinSongCount),
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
    ])
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
    now: Date = Date()
  )
    -> [SongMO] {
    let cutoff = now.addingTimeInterval(-Double(m) * 24 * 60 * 60)
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: nonWholeAlbumMinSongCount),
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      NSPredicate(format: "%K >= %@", #keyPath(SongMO.addedDate), cutoff as NSDate),
    ])
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
    now: Date = Date()
  )
    -> Int {
    let cutoff = now.addingTimeInterval(-Double(m) * 24 * 60 * 60)
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: nonWholeAlbumMinSongCount),
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      NSPredicate(format: "%K >= %@", #keyPath(SongMO.addedDate), cutoff as NSDate),
    ])
    return (try? context.count(for: fetchRequest)) ?? 0
  }
}
