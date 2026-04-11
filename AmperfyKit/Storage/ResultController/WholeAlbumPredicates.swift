//
//  WholeAlbumPredicates.swift
//  AmperfyKit
//
//  Created by implementer-amperfy on 2026-04-10.
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

/// Predicate builders for the "is a whole album" primitive.
///
/// The primitive answers the question *"is this release a whole album or EP,
/// as opposed to a single, a bag of singles, or a promotional release?"* It is
/// used by the Albums view "complete albums only" toggle and by the Home tab
/// new-albums section filter.
///
/// # Decision rule
///
/// An album is considered *whole* when **both** of the following hold:
///
///   1. It is **not** explicitly tagged `"single"` in the OpenSubsonic
///      `releaseTypes` metadata. An explicit `"single"` tag is the only
///      metadata value that *disqualifies* a release — everything else is
///      treated as "potentially a whole album".
///   2. It either (a) is explicitly tagged as `"album"` or `"ep"` (case
///      insensitive, substring — multi-value strings like
///      `"album, compilation"` match), OR (b) has `remoteSongCount` at least
///      `minSongCount`.
///
/// This shape means:
///
/// * A `"single"` with 5 tracks → not whole (metadata wins over count).
/// * An `"album"` with 0 tracks → whole (metadata wins over count).
/// * A `"compilation"` with `>= minSongCount` tracks → whole via count
///   fallback (compilations / soundtracks / live releases / etc. are not
///   singles, so the count gate applies).
/// * A `"compilation"` with `< minSongCount` tracks → not whole.
/// * No metadata, `>= minSongCount` tracks → whole via count fallback.
/// * No metadata, `< minSongCount` tracks → not whole.
///
/// See the test suite `WholeAlbumPredicatesTest` for the full truth table.
///
/// # Why `remoteSongCount` and not `songCount` or `songs.@count`
///
/// `remoteSongCount` is the server-reported track count and is populated on
/// the initial `getAlbumList2` sync. `songCount` is the locally-materialised
/// count (zero until `getAlbum` has been called for that album), and
/// `songs.@count` is zero on a fresh install until songs are synced. Using
/// `remoteSongCount` keeps the fallback stable on a fresh install where the
/// library has been listed but individual albums have not been drilled into.
///
/// # Thresholds
///
/// The Albums toggle uses `minSongCount = 3`. The Home new-albums filter also
/// uses `3`. The PR 2 recent-tracks widget will use `5` for its non-album
/// gate. See `spike/amperfy/BACKLOG.md` §4 for the threshold rationale.
public enum WholeAlbumPredicates {
  /// Predicate over `Album` (`AlbumMO`) that matches albums which are *whole*
  /// — i.e. either explicitly tagged as an album/EP via `releaseTypes`, or
  /// whose `remoteSongCount` is at least `minSongCount`.
  ///
  /// Use this with `NSFetchRequest<AlbumMO>` or as a sub-predicate of a
  /// compound `NSPredicate`.
  public static func wholeAlbum(minSongCount: Int16) -> NSPredicate {
    NSPredicate(
      format: """
      (NOT (releaseType CONTAINS[c] %@)) \
      AND \
      ( \
        (releaseType CONTAINS[c] %@ OR releaseType CONTAINS[c] %@) \
        OR remoteSongCount >= %d \
      )
      """,
      "single", "album", "ep", minSongCount
    )
  }

  /// Predicate over `Song` (`SongMO`) that matches songs whose parent album
  /// is **not** a whole album — i.e. the inverse of `wholeAlbum(minSongCount:)`
  /// lifted through the `album` relationship. Used by the PR 2 recent-tracks
  /// widget to surface only tracks from singles / bags of singles.
  public static func songFromNonWholeAlbum(minSongCount: Int16) -> NSPredicate {
    NSPredicate(
      format: """
      NOT ( \
      (NOT (album.releaseType CONTAINS[c] %@)) \
      AND \
      ( \
        (album.releaseType CONTAINS[c] %@ OR album.releaseType CONTAINS[c] %@) \
        OR album.remoteSongCount >= %d \
      ) \
      )
      """,
      "single", "album", "ep", minSongCount
    )
  }
}
