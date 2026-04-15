//
//  LocalTrackAdjacencyComputer.swift
//  AmperfyKit
//
//  Processes playlists in batches with a windowed algorithm to compute
//  pairwise song adjacency and co-membership scores.
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

public final class LocalTrackAdjacencyComputer {
  public let windowSize: Int
  public let playlistBatchSize: Int

  public init(
    windowSize: Int = TrackAdjacencyWeights.defaultWindowSize,
    playlistBatchSize: Int = 20
  ) {
    self.windowSize = windowSize
    self.playlistBatchSize = playlistBatchSize
  }

  /// Main entry point. Fetches playlists in batches, computes windowed scores,
  /// flushes to sink, then applies album bonuses.
  public func compute(provider: PlaylistDataProvider, sink: ScoredRelationSink) throws {
    try sink.beginComputation()

    var allSongIds = Set<String>()
    var batchOffset = 0

    // Phase 1: Playlist-based scoring
    while true {
      let playlists = provider.fetchPlaylistBatch(offset: batchOffset, limit: playlistBatchSize)
      guard !playlists.isEmpty else { break }

      var accumulator: [CanonicalPair: (adjacency: Float, coMembership: Float)] = [:]

      for playlist in playlists {
        allSongIds.formUnion(playlist.songIds)
        processPlaylist(playlist, into: &accumulator)
      }

      let relations = accumulator.map { pair, scores in
        ScoredRelation(
          songId1: pair.id1,
          songId2: pair.id2,
          adjacency: scores.adjacency,
          coMembership: scores.coMembership
        )
      }
      try sink.receiveBatch(relations)

      MemoryReporter.logMemory(label: "TrackAdjacency batch at offset \(batchOffset)")
      batchOffset += playlistBatchSize
    }

    // Phase 2: Album bonuses
    let albumGroups = provider.songsByAlbum(for: allSongIds)
    for (_, songIdsInAlbum) in albumGroups {
      try sink.applyAlbumBonus(TrackAdjacencyWeights.albumWeight, toSongIds: songIdsInAlbum)
    }

    try sink.finalizeComputation()
  }

  // MARK: - Private

  private func processPlaylist(
    _ playlist: PlaylistDescriptor,
    into accumulator: inout [CanonicalPair: (adjacency: Float, coMembership: Float)]
  ) {
    let songIds = playlist.songIds

    for indexI in 0 ..< songIds.count {
      let windowEnd = min(indexI + windowSize, songIds.count)
      for indexJ in (indexI + 1) ..< windowEnd {
        let pair = CanonicalPair(songIds[indexI], songIds[indexJ])
        var existing = accumulator[pair] ?? (adjacency: 0, coMembership: 0)
        existing.coMembership += TrackAdjacencyWeights.coMembershipWeight

        let distance = indexJ - indexI
        if distance == 1 {
          existing.adjacency += TrackAdjacencyWeights.adjacencyWeight1
        } else if distance == 2 {
          existing.adjacency += TrackAdjacencyWeights.adjacencyWeight2
        }

        accumulator[pair] = existing
      }
    }
  }
}
