//
//  DeckSeedResolution.swift
//  AmperfyKit
//
//  Resolves a DeckSeed into concrete seed track ids + provenance info that
//  DeckFusionEngine needs before it can query either pool.
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

// MARK: - DeckSeedResolution

/// Plain Sendable data extracted from a `DeckSeed` before crossing into the
/// concurrent pool fetches — deliberately holds no Core Data references.
public struct DeckSeedResolution: Sendable, Equatable {
  /// All track ids in the seed collection (playlist/album), or the most
  /// recent `historyLimit` distinct played track ids for `.recentHistory`.
  public let seedSongIds: [String]
  /// The seed's own collection id, to be excluded from results. `nil` for
  /// `.recentHistory` — there is no single collection to exclude.
  public let seedCollectionId: String?
  /// Human-readable name for the evidence-line template (design §5.2):
  /// the collection's name, or "your recent listening" for history.
  public let seedTitle: String

  public init(seedSongIds: [String], seedCollectionId: String?, seedTitle: String) {
    self.seedSongIds = seedSongIds
    self.seedCollectionId = seedCollectionId
    self.seedTitle = seedTitle
  }
}

// MARK: - DeckSeedResolver

enum DeckSeedResolver {
  /// Default "recent plays" window for `.recentHistory`, per
  /// `docs/contracts/adjacency-sidecar-api.md` §3.2's Director-settled OQ-4
  /// resolution: most recent 20 plays, deduped by track.
  static let defaultHistoryLimit = 20

  static func resolve(
    seed: DeckSeed,
    storage: LibraryStorage,
    account: Account,
    historyLimit: Int = defaultHistoryLimit
  )
    -> DeckSeedResolution {
    switch seed {
    case let .playlist(id):
      guard let playlist = storage.getPlaylist(for: account, id: id) else {
        return DeckSeedResolution(seedSongIds: [], seedCollectionId: id, seedTitle: "")
      }
      return DeckSeedResolution(
        seedSongIds: orderedDedupedSongIds(from: playlist.playables),
        seedCollectionId: playlist.id,
        seedTitle: playlist.name
      )

    case let .album(id):
      guard let album = storage.getAlbum(for: account, id: id, isDetailFaultResolution: false)
      else {
        return DeckSeedResolution(seedSongIds: [], seedCollectionId: id, seedTitle: "")
      }
      return DeckSeedResolution(
        seedSongIds: orderedDedupedSongIds(from: album.songs),
        seedCollectionId: album.id,
        seedTitle: album.name
      )

    case .recentHistory:
      let songs = storage.getRecentlyPlayedSongs(for: account, limit: historyLimit)
      return DeckSeedResolution(
        seedSongIds: songs.map(\.id),
        seedCollectionId: nil,
        seedTitle: "your recent listening"
      )
    }
  }

  private static func orderedDedupedSongIds(from playables: [AbstractPlayable]) -> [String] {
    var seenIds = Set<String>()
    var songIds = [String]()
    for playable in playables where seenIds.insert(playable.id).inserted {
      songIds.append(playable.id)
    }
    return songIds
  }
}
