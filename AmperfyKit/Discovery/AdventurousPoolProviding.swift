//
//  AdventurousPoolProviding.swift
//  AmperfyKit
//
//  The "Adventurous" pool source (design §1): Amperfy's own on-device
//  track-to-track similarity (AmperfyKit/Storage/TrackAdjacency), mapped up
//  to the collection level.
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

// MARK: - AdventurousPoolProviding

public protocol AdventurousPoolProviding: Sendable {
  /// Never throws network errors (it's on-device). `dataAvailable` distinguishes
  /// "legitimately zero good matches" (`results: [], dataAvailable: true`) from
  /// "no adjacency data computed yet" (`results: [], dataAvailable: false`) — the
  /// caller (`DeckFusionEngine`) treats the latter as this pool being
  /// "unreachable" for the §8 degraded-state UI. `dataAvailable` is `false` only
  /// when the underlying `TrackAdjacencyService` has no usable data for ANY of
  /// `seedSongIds`; if at least one seed track has data, it is `true` even if the
  /// resulting candidate list ends up empty after exclusions/aggregation.
  func candidates(
    seedSongIds: [String],
    kind: DeckCandidateKind,
    excluding: Set<String>,
    count: Int
  ) -> (results: [ScoredCandidate], dataAvailable: Bool)
}
