//
//  OnDeviceAdventurousPoolProvider.swift
//  AmperfyKit
//
//  AdventurousPoolProviding backed by the on-device track adjacency engine
//  (AmperfyKit/Storage/TrackAdjacency). That engine is TRACK-level only — this
//  type builds the missing track -> containing-collection mapping needed to
//  produce collection-level candidates for the Audition Deck.
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

// MARK: - OnDeviceAdventurousPoolProvider

/// Marked `@unchecked Sendable`: it holds an `Account`/`LibraryStorage` pair
/// (neither is `Sendable` — both wrap Core Data managed objects/contexts),
/// same accommodation `DefaultTrackAdjacencyService` itself already makes.
/// Like the rest of `LibraryStorage`'s call sites, callers are expected to use
/// this from the storage's own context queue (in practice: the main thread).
public final class OnDeviceAdventurousPoolProvider: AdventurousPoolProviding, @unchecked Sendable {
  private let storage: LibraryStorage
  private let account: Account
  private let adjacencyService: TrackAdjacencyQuerying

  public init(
    storage: LibraryStorage,
    account: Account,
    adjacencyService: TrackAdjacencyQuerying = DefaultTrackAdjacencyService.shared
  ) {
    self.storage = storage
    self.account = account
    self.adjacencyService = adjacencyService
  }

  public func candidates(
    seedSongIds: [String],
    kind: DeckCandidateKind,
    excluding: Set<String>,
    count: Int
  )
    -> (results: [ScoredCandidate], dataAvailable: Bool) {
    let dataAvailable = seedSongIds.contains { adjacencyService.hasData(for: $0) }
    guard dataAvailable else { return ([], false) }

    // Headroom so per-collection aggregation (below) has enough raw
    // track-level material to work with before it gets collapsed down to
    // `count` collections. 4x is a simple, generous multiplier — not tuned
    // against real data, cheap to revisit if decks feel thin.
    let perSeedTrackLimit = max(count * 4, 40)

    // Sum of contributing track scores per candidate collection — a simple,
    // explicit choice (over e.g. max or mean): a collection that shares many
    // strong track relations with the seed should outrank one that shares a
    // single strong one, which sum captures directly.
    var collectionScores = [String: Double]()

    for seedSongId in seedSongIds {
      let related = adjacencyService.topRelated(for: seedSongId, limit: perSeedTrackLimit)
      for relation in related {
        for collectionId in containingCollectionIds(songId: relation.songId, kind: kind) {
          // Excluding the seed's own collection id (passed in via `excluding`
          // by the caller) here means: even if one of its tracks is highly
          // related to itself/siblings, the seed collection can never win as
          // a candidate — this is what "excluding tracks already in the
          // seed's own collection" resolves to at the collection level.
          guard !excluding.contains(collectionId) else { continue }
          collectionScores[collectionId, default: 0] += Double(relation.score.total)
        }
      }
    }

    let ranked = collectionScores
      .sorted { $0.value > $1.value }
      .prefix(count)
      .map { ScoredCandidate(collectionId: $0.key, kind: kind, score: $0.value, seedTitle: "") }

    return (Array(ranked), true)
  }

  // MARK: - Private

  private func containingCollectionIds(songId: String, kind: DeckCandidateKind) -> [String] {
    guard let song = storage.getSong(for: account, id: songId) else { return [] }
    switch kind {
    case .album:
      guard let albumId = song.album?.id else { return [] }
      return [albumId]
    case .playlist:
      return storage.getPlaylists(for: account, containingSongId: songId).map(\.id)
    }
  }
}
