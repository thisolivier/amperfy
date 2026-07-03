//
//  DeckCandidate.swift
//  AmperfyKit
//
//  Data layer for the Audition Deck (Amperfy Discovery epic, sprint D4).
//  Pure value types shared by the two candidate pools and the fusion engine.
//  No Core Data entity references — the card view resolves artwork itself
//  via LibraryStorage lookup by id+kind (design doc §9).
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

// MARK: - DeckCandidateKind

public enum DeckCandidateKind: String, Equatable, Sendable {
  case album
  case playlist
}

// MARK: - DeckPool

/// Which of the two candidate pools (design §1/OQ-3) a result came from.
/// `adjacency` = the server-side adjacency-sidecar "familiar" pool.
/// `similar` = the on-device track-adjacency "adventurous" pool.
public enum DeckPool: String, Equatable, Sendable, Hashable {
  case adjacency
  case similar
}

// MARK: - DeckProvenance

/// Carries what a deck card's evidence line (design §5.2) is built from.
public struct DeckProvenance: Equatable, Sendable {
  public let pool: DeckPool
  /// The seed collection/track id, or "" for a history seed.
  public let seedRef: String
  /// Human-readable seed name for the evidence line template.
  public let seedTitle: String
  /// Set only when the deal's seed was `.recentHistory` (integration pass, design §5.2's third
  /// evidence-line template — "Because you've been playing <artist>"): the most-common artist
  /// among the resolved recent-plays seed songs (see `DeckSeedResolver`), or `nil` if no seed song
  /// had a resolvable artist. `nil` for `.playlist`/`.album` seeds — never fabricated, per design.
  public let seedArtist: String?

  public init(pool: DeckPool, seedRef: String, seedTitle: String, seedArtist: String? = nil) {
    self.pool = pool
    self.seedRef = seedRef
    self.seedTitle = seedTitle
    self.seedArtist = seedArtist
  }
}

// MARK: - DeckCandidate

/// One dealt card's worth of data. Mirrors design §9's client-facing shape
/// minus `artworkRef`.
public struct DeckCandidate: Identifiable, Equatable, Sendable {
  public let collectionId: String
  public let kind: DeckCandidateKind
  public let title: String
  public let subtitle: String?
  public let trackCount: Int
  public let totalDuration: TimeInterval
  public let year: Int?
  public let provenance: DeckProvenance

  public var id: String { collectionId }

  public init(
    collectionId: String,
    kind: DeckCandidateKind,
    title: String,
    subtitle: String?,
    trackCount: Int,
    totalDuration: TimeInterval,
    year: Int?,
    provenance: DeckProvenance
  ) {
    self.collectionId = collectionId
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.trackCount = trackCount
    self.totalDuration = totalDuration
    self.year = year
    self.provenance = provenance
  }
}

// MARK: - ScoredCandidate

/// A single pool's raw result, before it has been resolved into a full
/// `DeckCandidate` (title/subtitle/trackCount/etc. come from a LibraryStorage
/// or sidecar lookup performed by the caller).
public struct ScoredCandidate: Equatable, Sendable {
  public let collectionId: String
  public let kind: DeckCandidateKind
  public let score: Double
  public let seedTitle: String

  public init(collectionId: String, kind: DeckCandidateKind, score: Double, seedTitle: String) {
    self.collectionId = collectionId
    self.kind = kind
    self.score = score
    self.seedTitle = seedTitle
  }
}

// MARK: - DeckSeed

public enum DeckSeed: Equatable, Sendable {
  case playlist(id: String)
  case album(id: String)
  case recentHistory
}
