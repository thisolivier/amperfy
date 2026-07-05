//
//  DeckFusionEngine.swift
//  AmperfyKit
//
//  Orchestrates one Audition Deck "deal": resolves the seed, fetches both
//  pools concurrently, fuses them by blend (DeckBlendInterleaver), resolves
//  the winners into full DeckCandidates (DeckCandidateResolver). Blend fusion
//  is entirely client-side per sprint-Discovery-D4's OQ-3 architecture
//  clarification — there is no server "deal" endpoint.
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

// MARK: - DeckDealResult

public struct DeckDealResult: Sendable {
  public let candidates: [DeckCandidate]
  /// Pools that failed/had-no-data this deal (design §8). One pool degraded
  /// is not an error — `candidates` still comes from the live pool. Both
  /// degraded means `candidates` is empty and the caller should show the
  /// deck's Error state (§4.2).
  public let degradedPools: Set<DeckPool>

  public init(candidates: [DeckCandidate], degradedPools: Set<DeckPool>) {
    self.candidates = candidates
    self.degradedPools = degradedPools
  }
}

// MARK: - DeckFusionEngine

/// Marked `@unchecked Sendable`: it holds a `LibraryStorage` reference (not
/// itself `Sendable` — it wraps an `NSManagedObjectContext`). `deal(...)`
/// resolves the seed and reads storage synchronously, on the caller's queue,
/// *before* spawning the concurrent pool-fetch child tasks below — those
/// child tasks only capture plain Sendable data (ids/strings), never
/// `storage`/`account` themselves, so no non-Sendable state actually crosses
/// a concurrency boundary; `@unchecked` reflects that the compiler can't see
/// that invariant, not that the invariant doesn't hold. `DeckCandidateResolver`
/// (which does touch storage) runs back on the caller's queue after both
/// child tasks are awaited, for the same reason.
public final class DeckFusionEngine: @unchecked Sendable {
  /// Playlists above this track count are never dealt as candidates — matches
  /// the sidecar's server-side MAX_CANDIDATE_PLAYLIST_TRACKS default.
  public static let megaPlaylistTrackCeiling = 300

  private let familiarPool: FamiliarPoolProviding
  private let adventurousPool: AdventurousPoolProviding
  private let storage: LibraryStorage
  private let telemetry: DiscoveryTelemetry

  public init(
    familiarPool: FamiliarPoolProviding,
    adventurousPool: AdventurousPoolProviding,
    storage: LibraryStorage,
    telemetry: DiscoveryTelemetry = .shared
  ) {
    self.familiarPool = familiarPool
    self.adventurousPool = adventurousPool
    self.storage = storage
    self.telemetry = telemetry
  }

  /// `@MainActor`: matches this method's own documented invariant above — the seed resolution and
  /// storage/account reads happen synchronously "on the caller's queue" (in practice, the caller is
  /// always `AuditionDeckController`, itself `@MainActor`). Isolating `deal` to the caller's actor
  /// removes the need to send non-`Sendable` `Account`/`LibraryStorage` across an isolation
  /// boundary at all — the two pool fetches below still run concurrently as child tasks (via
  /// `async let`) because `fetchFamiliarOutcome`/`fetchAdventurousOutcome` are themselves
  /// `nonisolated` and only ever receive plain `Sendable` values (ids/strings/counts).
  @MainActor
  public func deal(
    seed: DeckSeed,
    kind: DeckCandidateKind,
    blend: Double,
    count: Int,
    excludeIds: Set<String>,
    account: Account
  ) async
    -> DeckDealResult {
    let passStart = DispatchTime.now()
    telemetry.appendDealEvent(
      label: "engine pass",
      detail: "blend=\(blend) kind=\(kind.rawValue) count=\(count)",
      milliseconds: 0
    )
    let seedResolutionStart = DispatchTime.now()
    let resolution = DeckSeedResolver.resolve(seed: seed, storage: storage, account: account)
    telemetry.appendDealEvent(
      label: "seed resolution",
      detail: "collection=\(resolution.seedCollectionId ?? "none") " +
        "songs=\(resolution.seedSongIds.count)",
      milliseconds: DiscoveryTelemetry.millisecondsSince(seedResolutionStart)
    )
    var excludeSet = excludeIds
    if let seedCollectionId = resolution.seedCollectionId {
      excludeSet.insert(seedCollectionId)
    }
    let seedRef = resolution.seedCollectionId ?? ""
    let seedTitle = resolution.seedTitle
    let seedArtist = resolution.seedArtist
    let seedSongIds = resolution.seedSongIds
    let seedCollectionParam: (id: String, kind: DeckCandidateKind)? = resolution
      .seedCollectionId.map { (id: $0, kind: kind) }

    // Over-fetch by the exclusion count (bounded): the pools rank globally and
    // know nothing about session de-dupe, so requesting exactly `count` means a
    // refresh/deal-more whose exclusions overlap the top-N can come back with
    // nothing even though fresh candidates exist further down the ranking —
    // observed live as a blend-change collapsing a 9-card deck to 2.
    let poolFetchCount = min(count + excludeSet.count, 60)
    async let familiarOutcome = fetchFamiliarOutcome(
      seedSongIds: seedSongIds,
      seedCollection: seedCollectionParam,
      kind: kind,
      count: poolFetchCount
    )
    async let adventurousOutcome = fetchAdventurousOutcome(
      seedSongIds: seedSongIds,
      kind: kind,
      excluding: excludeSet,
      count: poolFetchCount
    )
    let (familiarResult, adventurousResult) = await (familiarOutcome, adventurousOutcome)

    var degradedPools = Set<DeckPool>()
    if familiarResult.degraded { degradedPools.insert(.adjacency) }
    if adventurousResult.degraded { degradedPools.insert(.similar) }
    if degradedPools.count == 2 {
      telemetry.appendDealEvent(
        label: "engine pass done",
        detail: "dealt=0 degraded=[both pools]",
        milliseconds: DiscoveryTelemetry.millisecondsSince(passStart)
      )
      return DeckDealResult(candidates: [], degradedPools: degradedPools)
    }

    let resolveInterleaveStart = DispatchTime.now()
    let familiarTagged = familiarResult.results.map {
      PoolTaggedCandidate(scored: withSeedTitle($0, seedTitle), pool: .adjacency)
    }
    let adventurousTagged = adventurousResult.results.map {
      PoolTaggedCandidate(scored: withSeedTitle($0, seedTitle), pool: .similar)
    }

    let merged = DeckBlendInterleaver.interleave(
      familiar: familiarTagged,
      adventurous: adventurousTagged,
      blend: blend,
      count: count,
      excludeIds: excludeSet
    )

    let candidates = merged.compactMap {
      DeckCandidateResolver.resolve(
        $0,
        seedRef: seedRef,
        seedArtist: seedArtist,
        storage: storage,
        account: account
      )
    }.filter { candidate in
      // Mega-playlists (folder playlists, Spotify liked-songs imports) are
      // containers, not curated collections — never worth recommending
      // (user feedback, build-57 test drive). The sidecar applies the same
      // ceiling server-side (MAX_CANDIDATE_PLAYLIST_TRACKS); this covers the
      // on-device Adventurous pool too. Seeds are unaffected.
      candidate.kind != .playlist || candidate.trackCount <= Self.megaPlaylistTrackCeiling
    }
    telemetry.appendDealEvent(
      label: "resolve+interleave",
      detail: "merged=\(merged.count) resolved=\(candidates.count)",
      milliseconds: DiscoveryTelemetry.millisecondsSince(resolveInterleaveStart)
    )
    telemetry.appendDealEvent(
      label: "engine pass done",
      detail: "dealt=\(candidates.count) " +
        "degraded=[\(degradedPools.map(\.rawValue).sorted().joined(separator: ","))]",
      milliseconds: DiscoveryTelemetry.millisecondsSince(passStart)
    )

    return DeckDealResult(candidates: candidates, degradedPools: degradedPools)
  }

  // MARK: - Private

  private struct PoolOutcome {
    let results: [ScoredCandidate]
    let degraded: Bool
  }

  private func fetchFamiliarOutcome(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  ) async
    -> PoolOutcome {
    let fetchStart = DispatchTime.now()
    do {
      let results = try await familiarPool.fetchCandidates(
        seedSongIds: seedSongIds,
        seedCollection: seedCollection,
        kind: kind,
        count: count
      )
      telemetry.appendDealEvent(
        label: "familiar pool",
        detail: "ok candidates=\(results.count)",
        milliseconds: DiscoveryTelemetry.millisecondsSince(fetchStart)
      )
      return PoolOutcome(results: results, degraded: false)
    } catch {
      telemetry.appendDealEvent(
        label: "familiar pool",
        detail: "degraded error=\(error)",
        milliseconds: DiscoveryTelemetry.millisecondsSince(fetchStart)
      )
      return PoolOutcome(results: [], degraded: true)
    }
  }

  private func fetchAdventurousOutcome(
    seedSongIds: [String],
    kind: DeckCandidateKind,
    excluding: Set<String>,
    count: Int
  ) async
    -> PoolOutcome {
    let fetchStart = DispatchTime.now()
    let (results, dataAvailable) = adventurousPool.candidates(
      seedSongIds: seedSongIds,
      kind: kind,
      excluding: excluding,
      count: count
    )
    telemetry.appendDealEvent(
      label: "adventurous pool",
      detail: "candidates=\(results.count) dataAvailable=\(dataAvailable)",
      milliseconds: DiscoveryTelemetry.millisecondsSince(fetchStart)
    )
    return PoolOutcome(results: results, degraded: !dataAvailable)
  }

  /// The pool clients don't know the human-readable seed title (they only
  /// see ids) — DeckFusionEngine fills it in once, here, from the seed
  /// resolution.
  private func withSeedTitle(_ candidate: ScoredCandidate, _ seedTitle: String) -> ScoredCandidate {
    ScoredCandidate(
      collectionId: candidate.collectionId,
      kind: candidate.kind,
      score: candidate.score,
      seedTitle: seedTitle
    )
  }
}
