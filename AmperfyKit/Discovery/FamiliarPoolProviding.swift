//
//  FamiliarPoolProviding.swift
//  AmperfyKit
//
//  The "Familiar" pool source (design §1): adjacency-sidecar's
//  collection-similarity endpoints, fetched over HTTP.
//
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

// MARK: - DeckPoolError

public enum DeckPoolError: Error, Equatable {
  case unreachable
  case decodingFailed
}

// MARK: - FamiliarPoolProviding

public protocol FamiliarPoolProviding: Sendable {
  /// Fetches the "familiar" pool for a seed. Either `seedCollection` is supplied
  /// (routes to `GET /similar-collections`) or `seedSongIds` is non-empty with
  /// `seedCollection == nil` (routes to `GET /similar-from-history`).
  ///
  /// Throws `DeckPoolError.unreachable` on any network/HTTP failure (including
  /// any non-2xx status — unlike the sprite-manifest endpoint's documented
  /// 404-means-not-yet-rendered case, THESE two endpoints treat every non-2xx
  /// as unreachable, there is no meaningful 404 case for them). A clean 2xx
  /// response with an empty JSON array is a legitimate empty result, not an
  /// error, and is returned as `[]`.
  func fetchCandidates(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  ) async throws -> [ScoredCandidate]
}
