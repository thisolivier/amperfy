//
//  TrackAdjacencyStore.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 12 — Track Adjacency Engine).
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

import CoreData
import Foundation

// MARK: - SongPair

/// Order-independent pair of song IDs. SongPair("a","b") == SongPair("b","a").
public struct SongPair: Hashable, Codable, Equatable {
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

  public func contains(_ songId: String) -> Bool {
    id1 == songId || id2 == songId
  }

  public func otherSongId(from songId: String) -> String? {
    if id1 == songId { return id2 }
    if id2 == songId { return id1 }
    return nil
  }
}

// MARK: - SimilarityScore

/// Decomposed score with separate adjacency, co-membership, and album components.
public struct SimilarityScore: Codable, Equatable {
  public var adjacency: Float = 0
  public var coMembership: Float = 0
  public var album: Float = 0

  public var total: Float { adjacency + coMembership + album }

  public init(adjacency: Float = 0, coMembership: Float = 0, album: Float = 0) {
    self.adjacency = adjacency
    self.coMembership = coMembership
    self.album = album
  }
}

// MARK: - TrackAdjacencyStore

/// Computes pairwise similarity scores between songs based on playlist adjacency,
/// co-membership, and shared album. Scores are computed from Core Data playlist data,
/// persisted as JSON, and queried at runtime for "Related Tracks" UI.
public class TrackAdjacencyStore: @unchecked Sendable {
  // Scoring weights
  public static let adjacencyWeight1: Float = 3.0
  public static let adjacencyWeight2: Float = 2.0
  public static let coMembershipWeight: Float = 0.5
  public static let albumWeight: Float = 1.5
  public static let minimumThreshold: Float = 2.0

  /// Shared singleton for app-wide use.
  public static let shared = TrackAdjacencyStore()

  private(set) public var scores: [SongPair: SimilarityScore] = [:]
  public let persistenceURL: URL
  private(set) public var isStale: Bool = true

  public init(persistenceURL: URL? = nil) {
    if let url = persistenceURL {
      self.persistenceURL = url
    } else {
      let documentsDirectory = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first!
      self.persistenceURL = documentsDirectory
        .appendingPathComponent("track_adjacency.json")
    }
  }

  /// Computes scores if stale, on the current thread. Call from a background queue.
  public func computeIfNeeded(in context: NSManagedObjectContext) {
    guard isStale else { return }
    if !loadFromDisk() {
      compute(in: context)
      try? saveToDisk()
    }
  }

  // MARK: - Query API

  /// Returns top-N related songs for a given song, sorted by score descending.
  public func topRelated(
    for songId: String,
    limit: Int = 20
  )
    -> [(songId: String, score: SimilarityScore)] {
    var results: [(songId: String, score: SimilarityScore)] = []
    for (pair, score) in scores {
      if let otherId = pair.otherSongId(from: songId) {
        results.append((songId: otherId, score: score))
      }
    }
    results.sort { $0.score.total > $1.score.total }
    if results.count > limit {
      results = Array(results.prefix(limit))
    }
    return results
  }

  /// Returns true if any pair involving this song has total >= minimumThreshold.
  public func hasData(for songId: String) -> Bool {
    for (pair, score) in scores {
      if pair.contains(songId), score.total >= Self.minimumThreshold {
        return true
      }
    }
    return false
  }

  /// Returns the similarity score between two songs, or nil if no relationship exists.
  public func score(for songIdA: String, _ songIdB: String) -> SimilarityScore? {
    scores[SongPair(songIdA, songIdB)]
  }

  /// Returns how many playlists co-contain both songs. Used for source info display.
  public func playlistCoOccurrenceCount(
    songIdA: String,
    songIdB: String,
    in context: NSManagedObjectContext
  )
    -> Int {
    let score = scores[SongPair(songIdA, songIdB)]
    guard let coMembership = score?.coMembership, coMembership > 0 else { return 0 }
    // co-membership = count × 0.5, so count = co-membership / 0.5
    return Int(coMembership / Self.coMembershipWeight)
  }

  // MARK: - Compute

  /// Recomputes all scores from the current Core Data state.
  /// Thread-safe: uses `performAndWait` on the context's queue.
  public func compute(in context: NSManagedObjectContext) {
    var newScores: [SongPair: SimilarityScore] = [:]

    context.performAndWait {
      self.computeOnContextQueue(in: context, scores: &newScores)
    }

    scores = newScores
    isStale = false
  }

  private func computeOnContextQueue(
    in context: NSManagedObjectContext,
    scores newScores: inout [SongPair: SimilarityScore]
  ) {
    let playlists = fetchEligiblePlaylists(in: context)

    // Phase 1: Playlist-based scoring (co-membership + adjacency)
    for playlist in playlists {
      let songIds = extractDeduplicatedSongIds(from: playlist)
      guard songIds.count >= 2 else { continue }

      for indexI in 0 ..< songIds.count {
        for indexJ in (indexI + 1) ..< songIds.count {
          let pair = SongPair(songIds[indexI], songIds[indexJ])
          var existingScore = newScores[pair] ?? SimilarityScore()

          // Co-membership: every pair in the same playlist
          existingScore.coMembership += Self.coMembershipWeight

          // Adjacency bonuses
          let distance = indexJ - indexI
          if distance == 1 {
            existingScore.adjacency += Self.adjacencyWeight1
          } else if distance == 2 {
            existingScore.adjacency += Self.adjacencyWeight2
          }

          newScores[pair] = existingScore
        }
      }
    }

    // Phase 2: Album bonus (counted once per pair, not per playlist)
    applyAlbumBonuses(to: &newScores, in: context)
  }

  /// Marks the store as stale so it will be recomputed on next opportunity.
  public func invalidate() {
    isStale = true
  }

  // MARK: - Persistence

  /// Saves current scores to JSON on disk.
  public func saveToDisk() throws {
    let encoder = JSONEncoder()
    let wrapper = PersistenceWrapper(scores: scores)
    let data = try encoder.encode(wrapper)
    try data.write(to: persistenceURL, options: .atomic)
  }

  /// Loads scores from JSON on disk. Returns false if no file exists.
  @discardableResult
  public func loadFromDisk() -> Bool {
    guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
      return false
    }
    do {
      let data = try Data(contentsOf: persistenceURL)
      let decoder = JSONDecoder()
      let wrapper = try decoder.decode(PersistenceWrapper.self, from: data)
      scores = wrapper.scores
      isStale = false
      return true
    } catch {
      return false
    }
  }

  // MARK: - Private Helpers

  private func fetchEligiblePlaylists(
    in context: NSManagedObjectContext
  )
    -> [PlaylistMO] {
    let fetchRequest: NSFetchRequest<PlaylistMO> = PlaylistMO.fetchRequest()
    let notSmartPredicate = NSPredicate(
      format: "NOT (%K BEGINSWITH %@)",
      #keyPath(PlaylistMO.id),
      Playlist.smartPlaylistIdPrefix
    )
    let hasNamePredicate = NSPredicate(
      format: "%K != nil AND %K != %@",
      #keyPath(PlaylistMO.name),
      #keyPath(PlaylistMO.name),
      ""
    )
    // Exclude system playlists (player context, queue, shuffle, podcast)
    let notPlayerContextPredicate = NSPredicate(
      format: "%K == nil",
      #keyPath(PlaylistMO.playersContextPlaylist)
    )
    let notPlayerShuffledPredicate = NSPredicate(
      format: "%K == nil",
      #keyPath(PlaylistMO.playersShuffledContextPlaylist)
    )
    let notPlayerQueuePredicate = NSPredicate(
      format: "%K == nil",
      #keyPath(PlaylistMO.playersUserQueuePlaylist)
    )
    let notPodcastPredicate = NSPredicate(
      format: "%K == nil",
      #keyPath(PlaylistMO.playersPodcastPlaylist)
    )
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [
        notSmartPredicate,
        hasNamePredicate,
        notPlayerContextPredicate,
        notPlayerShuffledPredicate,
        notPlayerQueuePredicate,
        notPodcastPredicate,
      ]
    )
    do {
      return try context.fetch(fetchRequest)
    } catch {
      return []
    }
  }

  /// Extracts ordered, deduplicated song IDs from a playlist.
  /// Filters to SongMO only (excludes podcast episodes).
  /// Uses first occurrence for duplicates.
  private func extractDeduplicatedSongIds(from playlist: PlaylistMO) -> [String] {
    var seenIds = Set<String>()
    var songIds: [String] = []
    for item in playlist.items {
      guard item.playable is SongMO else { continue }
      let songId = item.playable.id
      if seenIds.insert(songId).inserted {
        songIds.append(songId)
      }
    }
    return songIds
  }

  /// Applies the album bonus (1.5) once per pair that shares an album.
  private func applyAlbumBonuses(
    to scores: inout [SongPair: SimilarityScore],
    in context: NSManagedObjectContext
  ) {
    // Build a map of albumId → [songId] from all songs referenced in our scores
    var allSongIds = Set<String>()
    for pair in scores.keys {
      allSongIds.insert(pair.id1)
      allSongIds.insert(pair.id2)
    }

    // Fetch songs that have albums
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(
      format: "%K IN %@ AND %K != nil",
      #keyPath(SongMO.id),
      allSongIds,
      #keyPath(SongMO.album)
    )
    guard let songs = try? context.fetch(fetchRequest) else { return }

    // Group song IDs by album object ID
    var albumToSongIds: [NSManagedObjectID: [String]] = [:]
    for song in songs {
      guard let albumMO = song.album else { continue }
      albumToSongIds[albumMO.objectID, default: []].append(song.id)
    }

    // For each album with 2+ songs, apply bonus to all pairs
    for (_, songIdsInAlbum) in albumToSongIds where songIdsInAlbum.count >= 2 {
      for indexI in 0 ..< songIdsInAlbum.count {
        for indexJ in (indexI + 1) ..< songIdsInAlbum.count {
          let pair = SongPair(songIdsInAlbum[indexI], songIdsInAlbum[indexJ])
          if scores[pair] != nil {
            // Only apply album bonus to pairs that already exist (from playlist co-membership)
            // UNLESS they share an album — the spec says album bonus applies even without playlists
          }
          var existingScore = scores[pair] ?? SimilarityScore()
          existingScore.album = Self.albumWeight
          scores[pair] = existingScore
        }
      }
    }
  }
}

// MARK: - PersistenceWrapper

/// Codable wrapper for dictionary serialization.
private struct PersistenceWrapper: Codable {
  let scores: [SongPair: SimilarityScore]

  enum CodingKeys: String, CodingKey {
    case entries
  }

  struct Entry: Codable {
    let pair: SongPair
    let score: SimilarityScore
  }

  init(scores: [SongPair: SimilarityScore]) {
    self.scores = scores
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decode([Entry].self, forKey: .entries)
    var decoded: [SongPair: SimilarityScore] = [:]
    decoded.reserveCapacity(entries.count)
    for entry in entries {
      decoded[entry.pair] = entry.score
    }
    self.scores = decoded
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let entries = scores.map { Entry(pair: $0.key, score: $0.value) }
    try container.encode(entries, forKey: .entries)
  }
}
