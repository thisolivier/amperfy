//
//  TrackAdjacencyProtocols.swift
//  AmperfyKit
//
//  Track Adjacency Engine v2 — protocol-first architecture.
//  Separates computation, storage, and query concerns so the
//  computation engine can be swapped for a server-side implementation.
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

// MARK: - ScoredRelation

/// A scored relationship between two songs. Song IDs are canonically
/// ordered (id1 < id2) so lookup is direction-independent.
public struct ScoredRelation: Sendable, Equatable {
  public let songId1: String
  public let songId2: String
  public var adjacency: Float
  public var coMembership: Float
  public var album: Float
  public var total: Float { adjacency + coMembership + album }

  public init(
    songId1: String,
    songId2: String,
    adjacency: Float = 0,
    coMembership: Float = 0,
    album: Float = 0
  ) {
    if songId1 <= songId2 {
      self.songId1 = songId1
      self.songId2 = songId2
    } else {
      self.songId1 = songId2
      self.songId2 = songId1
    }
    self.adjacency = adjacency
    self.coMembership = coMembership
    self.album = album
  }

  /// Returns the other song's ID given one of the pair, or nil if not in this pair.
  public func otherSongId(from songId: String) -> String? {
    if songId1 == songId { return songId2 }
    if songId2 == songId { return songId1 }
    return nil
  }

  /// Returns true if this pair contains the given song ID.
  public func contains(_ songId: String) -> Bool {
    songId1 == songId || songId2 == songId
  }
}

// MARK: - PlaylistDescriptor

/// Lightweight value type representing a playlist's ordered song list.
/// Decouples the computation engine from Core Data.
public struct PlaylistDescriptor: Sendable {
  public let playlistId: String
  public let songIds: [String]

  public init(playlistId: String, songIds: [String]) {
    self.playlistId = playlistId
    self.songIds = songIds
  }
}

// MARK: - CanonicalPair

/// Hash-friendly key for accumulating scores during computation.
/// Order-independent: CanonicalPair("b","a") == CanonicalPair("a","b").
public struct CanonicalPair: Hashable, Equatable {
  public let id1: String
  public let id2: String

  public init(_ songIdA: String, _ songIdB: String) {
    if songIdA <= songIdB {
      self.id1 = songIdA
      self.id2 = songIdB
    } else {
      self.id1 = songIdB
      self.id2 = songIdA
    }
  }
}

// MARK: - PlaylistDataProvider

/// Abstracts playlist/song data access so the computation engine
/// does not depend on Core Data. A server implementation would
/// provide its own data source.
public protocol PlaylistDataProvider {
  /// Returns lightweight playlist descriptors in batches.
  func fetchPlaylistBatch(offset: Int, limit: Int) -> [PlaylistDescriptor]

  /// Returns song IDs grouped by album ID, for songs in the given set.
  /// Only returns albums with 2+ songs in the set.
  func songsByAlbum(for songIds: Set<String>) -> [String: [String]]
}

// MARK: - ScoredRelationSink

/// Receives computed relations in batches for persistence.
/// The storage layer implements this protocol.
public protocol ScoredRelationSink {
  /// Prepares for a fresh computation pass (clears existing data).
  func beginComputation() throws

  /// Receives a batch of relations to upsert. Scores for existing
  /// pairs are accumulated (added), not replaced.
  func receiveBatch(_ relations: [ScoredRelation]) throws

  /// Applies album bonus to all existing pairs where both songs
  /// share the given album.
  func applyAlbumBonus(_ bonus: Float, toSongIds songIds: [String]) throws

  /// Marks computation as complete (updates metadata, optimizes).
  func finalizeComputation() throws
}

// MARK: - TrackAdjacencyQuerying

/// Read-only query interface used by the UI layer.
public protocol TrackAdjacencyQuerying {
  /// Returns top-N related songs sorted by total score descending.
  func topRelated(
    for songId: String,
    limit: Int
  ) -> [(songId: String, score: ScoredRelation)]

  /// Returns true if any scored pair for this song meets the threshold.
  func hasData(for songId: String) -> Bool

  /// Returns the score between two songs, or nil if no relationship.
  func score(for songIdA: String, _ songIdB: String) -> ScoredRelation?

  /// Returns the number of playlists that co-contain both songs.
  func playlistCoOccurrenceCount(songIdA: String, songIdB: String) -> Int
}

// MARK: - TrackAdjacencyService

/// Top-level orchestrator combining computation, storage, and queries.
/// This is the main entry point that replaces TrackAdjacencyStore.shared.
public protocol TrackAdjacencyService: TrackAdjacencyQuerying {
  var isStale: Bool { get }
  func computeIfNeeded()
  func invalidate()
}

// MARK: - TrackAdjacencyWeights

public enum TrackAdjacencyWeights {
  public static let adjacencyWeight1: Float = 3.0
  public static let adjacencyWeight2: Float = 2.0
  public static let coMembershipWeight: Float = 0.5
  public static let albumWeight: Float = 1.5
  public static let minimumThreshold: Float = 1.0
  public static let defaultWindowSize: Int = 10
}
