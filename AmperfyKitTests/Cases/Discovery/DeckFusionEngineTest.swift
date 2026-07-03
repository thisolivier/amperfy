//
//  DeckFusionEngineTest.swift
//  AmperfyKitTests
//
//  Tests for the Audition Deck's client-side blend fusion (Discovery sprint
//  D4). Fakes both pool protocols so the interleave/dedupe/degraded-pool
//  logic can be exercised without any real network or on-device adjacency
//  computation.
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

@testable import AmperfyKit
import XCTest

// MARK: - FakeFamiliarPool

private final class FakeFamiliarPool: FamiliarPoolProviding, @unchecked Sendable {
  var results: [ScoredCandidate] = []
  var errorToThrow: DeckPoolError?

  func fetchCandidates(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  ) async throws -> [ScoredCandidate] {
    if let errorToThrow { throw errorToThrow }
    return Array(results.prefix(count))
  }
}

// MARK: - FakeAdventurousPool

private final class FakeAdventurousPool: AdventurousPoolProviding, @unchecked Sendable {
  var results: [ScoredCandidate] = []
  var dataAvailable = true

  func candidates(
    seedSongIds: [String],
    kind: DeckCandidateKind,
    excluding: Set<String>,
    count: Int
  )
    -> (results: [ScoredCandidate], dataAvailable: Bool) {
    guard dataAvailable else { return ([], false) }
    let filtered = results.filter { !excluding.contains($0.collectionId) }
    return (Array(filtered.prefix(count)), true)
  }
}

// MARK: - DeckFusionEngineTest

@MainActor
class DeckFusionEngineTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var familiarPool: FakeFamiliarPool!
  var adventurousPool: FakeAdventurousPool!
  var engine: DeckFusionEngine!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    familiarPool = FakeFamiliarPool()
    adventurousPool = FakeAdventurousPool()
    engine = DeckFusionEngine(
      familiarPool: familiarPool,
      adventurousPool: adventurousPool,
      storage: library
    )

    // Seed album, so DeckSeedResolver has something real to resolve and its
    // id lands in the exclude set automatically.
    makeAlbum(id: "seed-album", name: "Seed Album")
    // Candidate albums both pools' fakes can reference — DeckCandidateResolver
    // needs these to actually exist to resolve a ScoredCandidate into a
    // DeckCandidate.
    for suffix in ["fa1", "fa2", "fa3", "fa4", "av1", "av2", "av3", "av4"] {
      makeAlbum(id: suffix, name: "Album \(suffix)")
    }
    library.saveContext()
  }

  @discardableResult
  private func makeAlbum(id: String, name: String) -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.name = name
    return album
  }

  private func candidate(_ id: String, score: Double) -> ScoredCandidate {
    ScoredCandidate(collectionId: id, kind: .album, score: score, seedTitle: "")
  }

  // MARK: - blend = 0 -> adjacency-only

  func testBlendZeroReturnsAdjacencyPoolOnly() async {
    familiarPool.results = ["fa1", "fa2", "fa3"].map { candidate($0, score: 1) }
    adventurousPool.results = ["av1", "av2", "av3"].map { candidate($0, score: 1) }

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 0,
      count: 3,
      excludeIds: [],
      account: account
    )

    XCTAssertEqual(result.candidates.map(\.collectionId), ["fa1", "fa2", "fa3"])
    XCTAssertTrue(result.candidates.allSatisfy { $0.provenance.pool == .adjacency })
    XCTAssertTrue(result.degradedPools.isEmpty)
  }

  // MARK: - blend = 1 -> similar-only

  func testBlendOneReturnsSimilarPoolOnly() async {
    familiarPool.results = ["fa1", "fa2", "fa3"].map { candidate($0, score: 1) }
    adventurousPool.results = ["av1", "av2", "av3"].map { candidate($0, score: 1) }

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 1,
      count: 3,
      excludeIds: [],
      account: account
    )

    XCTAssertEqual(result.candidates.map(\.collectionId), ["av1", "av2", "av3"])
    XCTAssertTrue(result.candidates.allSatisfy { $0.provenance.pool == .similar })
    XCTAssertTrue(result.degradedPools.isEmpty)
  }

  // MARK: - blend = 0.5 -> proportional (alternating) mix

  func testBlendHalfInterleavesProportionally() async {
    familiarPool.results = ["fa1", "fa2", "fa3", "fa4"].map { candidate($0, score: 1) }
    adventurousPool.results = ["av1", "av2", "av3", "av4"].map { candidate($0, score: 1) }

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 0.5,
      count: 4,
      excludeIds: [],
      account: account
    )

    // Equal shares produce an exact alternating pattern from the first pick
    // (see DeckBlendInterleaver's doc comment): F, A, F, A.
    XCTAssertEqual(result.candidates.map(\.collectionId), ["fa1", "av1", "fa2", "av2"])
  }

  // MARK: - both pools degraded -> empty + both flagged

  func testBothPoolsDegradedReturnsEmptyAndBothFlagged() async {
    familiarPool.errorToThrow = .unreachable
    adventurousPool.dataAvailable = false

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 0.5,
      count: 4,
      excludeIds: [],
      account: account
    )

    XCTAssertTrue(result.candidates.isEmpty)
    XCTAssertEqual(result.degradedPools, [.adjacency, .similar])
  }

  // MARK: - one pool degraded -> still returns candidates, flags that pool only

  func testOnePoolDegradedStillReturnsLivePoolResults() async {
    familiarPool.errorToThrow = .unreachable
    adventurousPool.results = ["av1", "av2"].map { candidate($0, score: 1) }
    adventurousPool.dataAvailable = true

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 0.5,
      count: 4,
      excludeIds: [],
      account: account
    )

    XCTAssertEqual(result.candidates.map(\.collectionId), ["av1", "av2"])
    XCTAssertEqual(result.degradedPools, [.adjacency])
  }

  // MARK: - dedup against excludeIds and the seed's own id

  func testDedupesAgainstExcludeIdsSeedIdAndCrossPoolDuplicates() async {
    // "fa1" is a duplicate the caller already dealt this session; "seed-album"
    // is the seed itself; "fa2" appears in both pools' fake results.
    familiarPool.results = ["fa1", "seed-album", "fa2", "fa3"].map { candidate($0, score: 1) }
    adventurousPool.results = ["fa2", "av1"].map { candidate($0, score: 1) }

    let result = await engine.deal(
      seed: .album(id: "seed-album"),
      kind: .album,
      blend: 0.5,
      count: 10,
      excludeIds: ["fa1"],
      account: account
    )

    let ids = result.candidates.map(\.collectionId)
    XCTAssertEqual(ids.count, Set(ids).count, "no collectionId should repeat")
    XCTAssertFalse(ids.contains("fa1"), "excludeIds entry must not appear")
    XCTAssertFalse(ids.contains("seed-album"), "seed's own id must not appear")
    XCTAssertEqual(ids.filter { $0 == "fa2" }.count, 1, "cross-pool duplicate must appear once")
  }
}
