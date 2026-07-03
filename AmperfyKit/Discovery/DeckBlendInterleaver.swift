//
//  DeckBlendInterleaver.swift
//  AmperfyKit
//
//  The client-side blend fusion algorithm (sprint-Discovery-D4's OQ-3
//  architecture clarification: fusion is entirely client-side, there is no
//  server "deal" endpoint — this is the merge of the two already-fetched pools).
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

// MARK: - PoolTaggedCandidate

/// A pool result that still remembers which pool it came from — needed so
/// `DeckProvenance.pool` survives the merge (the evidence line template,
/// design §5.2, depends on it).
struct PoolTaggedCandidate {
  let scored: ScoredCandidate
  let pool: DeckPool
}

// MARK: - DeckBlendInterleaver

/// Merges the "familiar" (adjacency) and "adventurous" (similar) pools into a
/// single ranked list, weighted by `blend` ∈ [0, 1].
///
/// **Algorithm ("deficit round robin" / Bresenham-style weighted interleave):**
/// `blend == 0` and `blend == 1` are exact — they draw *only* from the
/// adjacency pool or *only* from the similar pool respectively, never falling
/// back to the other one even if the chosen pool runs out early (so a caller
/// asking for adjacency-only-at-blend-0 never silently gets similar-pool
/// results mixed in). For `0 < blend < 1`: each pool has a target share
/// (`1 - blend` for adjacency, `blend` for similar). We walk a virtual
/// timeline one pick at a time; at each step both pools accumulate their
/// target share as "credit" (`credit += share`), and we draw from whichever
/// pool has the larger accumulated credit among those that still have
/// unconsumed candidates, then subtract 1 from that pool's credit (the
/// "deficit" it just spent). This is the standard fair-queueing trick for
/// turning a continuous ratio into a discrete interleave: over many picks the
/// long-run draw ratio converges exactly to `blend`, and for simple ratios
/// (e.g. 0.5) it produces an exact alternating pattern from the first pick,
/// rather than clumping. If one pool is exhausted before `count` picks are
/// reached, the other pool fills the remainder (this only applies to the
/// interior 0 < blend < 1 case — see above for the 0/1 boundary behavior).
/// Duplicate `collectionId`s (already in `excludeIds`, or already picked
/// earlier in this same interleave) are skipped without consuming a `count`
/// slot; pool indices still advance past them.
enum DeckBlendInterleaver {
  static func interleave(
    familiar: [PoolTaggedCandidate],
    adventurous: [PoolTaggedCandidate],
    blend: Double,
    count: Int,
    excludeIds: Set<String>
  )
    -> [PoolTaggedCandidate] {
    let clampedBlend = min(max(blend, 0), 1)
    var seenIds = excludeIds
    var picked = [PoolTaggedCandidate]()

    func take(_ candidate: PoolTaggedCandidate) {
      guard picked.count < count else { return }
      if seenIds.insert(candidate.scored.collectionId).inserted {
        picked.append(candidate)
      }
    }

    if clampedBlend <= 0 {
      for candidate in familiar where picked.count < count { take(candidate) }
      return picked
    }
    if clampedBlend >= 1 {
      for candidate in adventurous where picked.count < count { take(candidate) }
      return picked
    }

    let familiarShare = 1 - clampedBlend
    let adventurousShare = clampedBlend
    var familiarCredit = 0.0
    var adventurousCredit = 0.0
    var familiarIndex = 0
    var adventurousIndex = 0

    while picked.count < count, familiarIndex < familiar.count || adventurousIndex < adventurous
      .count {
      familiarCredit += familiarShare
      adventurousCredit += adventurousShare

      let familiarAvailable = familiarIndex < familiar.count
      let adventurousAvailable = adventurousIndex < adventurous.count

      let drawFromFamiliar: Bool
      switch (familiarAvailable, adventurousAvailable) {
      case (true, true): drawFromFamiliar = familiarCredit >= adventurousCredit
      case (true, false): drawFromFamiliar = true
      case (false, true): drawFromFamiliar = false
      case (false, false): return picked
      }

      if drawFromFamiliar {
        take(familiar[familiarIndex])
        familiarIndex += 1
        familiarCredit -= 1
      } else {
        take(adventurous[adventurousIndex])
        adventurousIndex += 1
        adventurousCredit -= 1
      }
    }

    return picked
  }
}
