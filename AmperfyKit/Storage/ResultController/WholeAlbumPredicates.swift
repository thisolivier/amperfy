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
/// The primitive answers the question *"is this release a whole album, as
/// opposed to a single or a bag of singles?"* It is used by the Albums view
/// "complete albums only" toggle, the Home tab new-albums section filter, and
/// the PR 2 recent-tracks widget's exclusion predicate.
///
/// # Decision rule
///
/// An album is considered *whole* iff **both** of the following hold:
///
///   1. It is **not** explicitly tagged `"single"` in the OpenSubsonic
///      `releaseTypes` metadata. `"single"` is the only metadata value that
///      disqualifies a release.
///   2. Its `remoteSongCount` is at least `minSongCount`.
///
/// Metadata other than `"single"` is ignored for positive matching. Earlier
/// versions of this primitive used `"album"` / `"ep"` as a positive signal,
/// but experience with real-world Navidrome libraries showed the metadata
/// path was:
///
///   * **unreliably populated** — `getAlbumList2` often omits `releaseTypes`
///     entirely, so most albums arrive with `releaseType == nil`;
///   * **untrustworthy when populated** — bad ID3 grouping in the user's
///     library lets single-track "albums" slip through a metadata-positive
///     filter; and
///   * **vulnerable to a Core Data / SQLite NULL-handling pitfall** — a
///     predicate of the form `NOT (releaseType CONTAINS[c] 'single')` is NULL
///     (not `true`) when `releaseType` is nil, and `NULL AND <anything>` is
///     NULL, which silently excludes every nil-metadata album from the
///     result set. The explicit `releaseType == nil OR ...` guard in the
///     builders below short-circuits before the NULL pitfall kicks in.
///
/// The track-count floor alone, with `"single"` as a veto, is robust to all
/// three failure modes.
///
/// Consequences of the rule:
///
///   * A `"single"` with 10 tracks → not whole (metadata veto).
///   * An `"album"` with 1 track   → not whole (fails count floor).
///   * An `"ep"` with 2 tracks at threshold 3 → not whole (fails count
///     floor). Legitimate 2-track EPs are an intentionally unsupported edge
///     case — users can find them via search or the unfiltered Albums view.
///   * Nil metadata with `>= minSongCount` tracks → whole (the happy path
///     for the majority of a typical Navidrome library).
///   * Nil metadata with `< minSongCount` tracks → not whole.
///   * `"compilation"` with `>= minSongCount` tracks → whole via count.
///   * `"album, compilation"` with `>= minSongCount` tracks → whole via count.
///
/// See the test suite `WholeAlbumPredicatesTest` for the full truth table
/// and `spike/amperfy/BACKLOG.md` §1.1 / §4 for the decision log.
///
/// # Why `remoteSongCount` and not `songCount` or `songs.@count`
///
/// `remoteSongCount` is the server-reported track count and is populated on
/// the initial `getAlbumList2` sync. `songCount` is the locally-materialised
/// count (zero until `getAlbum` has been called for that album), and
/// `songs.@count` is zero on a fresh install until songs are synced. Using
/// `remoteSongCount` keeps the primitive stable on a fresh install where the
/// library has been listed but individual albums have not been drilled into.
///
/// # Thresholds
///
/// The Albums toggle uses `minSongCount = 3`. The Home new-albums filter also
/// uses `3`. The PR 2 recent-tracks widget uses `5` for its non-album gate.
/// See `spike/amperfy/BACKLOG.md` §4 for the threshold rationale.
public enum WholeAlbumPredicates {
  /// Predicate over `Album` (`AlbumMO`) that matches albums which are
  /// *whole* — i.e. not explicitly tagged `"single"` and with
  /// `remoteSongCount >= minSongCount`.
  ///
  /// The `releaseType == nil OR ...` guard is load-bearing: without it, the
  /// SQLite NULL-propagation pitfall silently excludes every nil-metadata
  /// album from the result set.
  public static func wholeAlbum(minSongCount: Int16) -> NSPredicate {
    NSPredicate(
      format: """
      (releaseType == nil OR NOT (releaseType CONTAINS[c] %@)) \
      AND remoteSongCount >= %d
      """,
      "single", minSongCount
    )
  }

  /// Predicate over `Song` (`SongMO`) that matches songs whose parent album
  /// is **not** a whole album — the De Morgan inverse of
  /// `wholeAlbum(minSongCount:)` lifted through the `album` relationship.
  /// Used by the PR 2 recent-tracks widget to surface only tracks from
  /// singles / bags of singles.
  ///
  /// The `album.releaseType != nil AND ...` guard mirrors the NULL-safety
  /// shape of the positive predicate: a nil-metadata parent album is
  /// classified purely by `album.remoteSongCount < minSongCount`, never by
  /// a NULL-poisoned metadata branch.
  public static func songFromNonWholeAlbum(minSongCount: Int16) -> NSPredicate {
    NSPredicate(
      format: """
      (album.releaseType != nil AND album.releaseType CONTAINS[c] %@) \
      OR album.remoteSongCount < %d
      """,
      "single", minSongCount
    )
  }
}
