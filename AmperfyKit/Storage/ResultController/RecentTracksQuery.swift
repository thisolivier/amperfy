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
/// filter. See `spike/amperfy/BACKLOG.md` §1.1 + §4. `topNAnyAlbum` is the
/// exception: it deliberately omits this filter (see its doc comment) so
/// that `widgetTracks(context:minimumCount:)` can pad the widget's display
/// list even for libraries whose recent additions are entirely whole
/// albums.
///
/// The entry points return raw `SongMO` arrays. Callers wrap them into
/// `Song` entity wrappers (the wrapping is left to the caller to keep this
/// helper free of presentation concerns and easier to unit-test).
public enum RecentTracksQuery {
  /// The non-whole-album threshold used by the recent-tracks widget. Singles
  /// and bags-of-singles below this track count are surfaced; anything at or
  /// above is treated as a whole album and excluded.
  public static let nonWholeAlbumMinSongCount: Int16 = 5

  /// Returns up to `n` songs sorted by `addedDate` DESC, filtered to songs
  /// whose parent album is not a whole album. This is the **stage 1
  /// ("qualifying")** fetch: it highlights individually-added tracks first,
  /// but a library whose recent additions are all whole albums can
  /// legitimately return zero rows here. It is no longer the sole source of
  /// the widget's display list — see `widgetTracks(context:minimumCount:)`,
  /// which pads stage 1's results with `topNAnyAlbum` when they fall short
  /// of the desired minimum. Used by:
  ///
  /// * `widgetTracks(context:minimumCount:)` as its stage-1 "qualifying"
  ///   fetch.
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

  /// Returns up to `n` songs sorted by `addedDate` DESC, WITHOUT the
  /// whole-album exclusion applied — the "stage 2 / any-album" fallback
  /// fetch. Still applies the "song must be playable" guard
  /// (`SongMO.excludeServerDeleteUncachedSongsFetchPredicate`) so the widget
  /// never surfaces ghost rows for songs whose backing files have been
  /// removed server-side without a local cache.
  ///
  /// Used by `widgetTracks(context:minimumCount:)` to pad out the display
  /// list when `topN` returns fewer than `minimumCount` qualifying songs —
  /// e.g. a library whose recent additions are entirely whole albums, which
  /// would otherwise yield zero rows from `topN` no matter how large or
  /// active the library is.
  public static func topNAnyAlbum(
    context: NSManagedObjectContext,
    n: Int
  )
    -> [SongMO] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.addedDateSortedFetchRequest
    fetchRequest.fetchLimit = n
    fetchRequest.predicate = SongMO.excludeServerDeleteUncachedSongsFetchPredicate
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    return (try? context.fetch(fetchRequest)) ?? []
  }

  /// The home widget's display-list orchestrator: a two-stage fetch that
  /// guarantees the widget always has something to show (down to the size
  /// of the whole library) regardless of how the qualifying-song predicate
  /// in `topN` fares.
  ///
  /// Stage 1 fetches `topN(context:n: minimumCount)` — the qualifying,
  /// non-whole-album songs, most recent first. If that alone meets
  /// `minimumCount`, it is returned unchanged (the common case for an
  /// actively-curated library keeps its existing behaviour). Otherwise,
  /// stage 2 fetches `topNAnyAlbum` with a widened window
  /// (`minimumCount + primary.count` candidates) regardless of the
  /// whole-album predicate, removes any songs already present in stage 1's
  /// results (by `id`), and appends just enough of what remains — in their
  /// own recency order — to reach `minimumCount` rows.
  ///
  /// The qualifying songs always lead the returned array, followed by the
  /// padding songs; the two groups are never re-sorted together, since
  /// surfacing individually-added tracks first is intentional. If the
  /// library has fewer than `minimumCount` songs in total (of any kind),
  /// the returned array is correspondingly shorter — "show everything that
  /// exists" rather than an error or an empty result.
  public static func widgetTracks(
    context: NSManagedObjectContext,
    minimumCount: Int
  )
    -> [SongMO] {
    let primary = topN(context: context, n: minimumCount)
    guard primary.count < minimumCount else { return primary }

    let primaryIds = Set(primary.map(\.id))
    let candidates = topNAnyAlbum(context: context, n: minimumCount + primary.count)
    let padding = candidates
      .filter { !primaryIds.contains($0.id) }
      .prefix(minimumCount - primary.count)
    return primary + padding
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
