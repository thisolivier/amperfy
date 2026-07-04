import AmperfyKit
import Foundation

// MARK: - AuditionDeckController dealing/refresh flow

/// Split out of `AuditionDeckController.swift` to keep both files comfortably under the project's
/// ~200-line convention — this is the deck's whole dealing/refresh/Deal-More flow (design
/// §3.1/§4.2/§8).
///
/// **Deck v2 pool policy (algorithm parity proven, docs/qa/adjacency-parity-report.md):** every
/// deal runs the fusion engine at effective blend 0.0 — Familiar/sidecar only. If the familiar
/// pool comes back degraded (unreachable/failed, per `DeckDealResult.degradedPools`), the deal is
/// silently retried at blend 1.0 — the on-device Adventurous pool. No degraded-warning UI; both
/// pools down is still the Error state.
extension AuditionDeckController {
  /// Fusion-engine blend for the primary deal: 0.0 = Familiar (sidecar) only.
  private static let sidecarBlend = 0.0
  /// Fusion-engine blend for the fallback deal: 1.0 = Adventurous (on-device) only.
  private static let onDeviceFallbackBlend = 1.0

  /// One deal round at the Deck v2 pool policy above. Also publishes `degradedPools` (kept for
  /// internal state/error detection — the warning chip UI is gone).
  private func dealFromPools(
    seed: DeckSeed,
    kind: DeckCandidateKind,
    count: Int
  ) async
    -> DeckDealResult {
    let sidecarResult = await fusionEngine.deal(
      seed: seed, kind: kind, blend: Self.sidecarBlend, count: count,
      excludeIds: excludeIds, account: account
    )
    guard sidecarResult.degradedPools.contains(.adjacency) else {
      degradedPools = sidecarResult.degradedPools
      return sidecarResult
    }
    let fallbackResult = await fusionEngine.deal(
      seed: seed, kind: kind, blend: Self.onDeviceFallbackBlend, count: count,
      excludeIds: excludeIds, account: account
    )
    // Surface the sidecar's degradation alongside the fallback's own report so
    // `isBothPoolsDown` still recognizes the everything-unreachable case.
    degradedPools = fallbackResult.degradedPools.union([.adjacency])
    return fallbackResult
  }

  func deal(seed: DeckSeed, kind: DeckCandidateKind) async {
    currentSeed = seed
    currentKind = kind
    lifecycleState = .dealing

    let result = await dealFromPools(seed: seed, kind: kind, count: deckLength)
    applyDealtCandidates(result, appending: false)

    if candidates.isEmpty {
      lifecycleState = AuditionDeckDegradedPoolMessage.isBothPoolsDown(degradedPools)
        ? .error(message: "Recommendations unavailable right now")
        : .empty
    } else {
      lifecycleState = .populated
      scrollPositionId = candidates.first?.id
    }
  }

  /// Re-deals with the same seed/kind as the last `deal(...)` call — the Error state's "Retry"
  /// (design §4.2).
  func redeal() async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    await deal(seed: seed, kind: kind)
  }

  /// Appends a fresh deal after the current last card (design §5.4/§5.5's "Deal <n> more").
  ///
  /// Guarded against re-entrancy via `dealingGate` (shared with `refresh()`, declared on
  /// `AuditionDeckController`) because both mutate
  /// `candidates`/`excludeIds`/`likedBeforeSessionIds`, and letting either run while the other is
  /// still awaiting its own pool round trip is the confirmed bug this guard closes: the slower
  /// call's eventual `candidates` write would otherwise be built against state that predates the
  /// faster call's own mutation, silently discarding it.
  ///
  /// A same-kind collision (a duplicate "Deal more" tap landing while one is already in flight) is
  /// simply ignored (`ignoreIfSameKindInFlight: true`) — a second identical tap expresses no
  /// "newer intent" a fresh fetch could serve. A cross-kind collision (`refresh()` is running)
  /// waits instead of cancelling — abandoning `refresh()` mid-flight would risk applying its
  /// pinning logic against half-updated state, so it is simply left to finish first.
  func dealMore() async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    await dealingGate.run(kind: .dealMore, ignoreIfSameKindInFlight: true) { [weak self] in
      await self?.performDealMore(seed: seed, kind: kind)
    }
  }

  private func performDealMore(seed: DeckSeed, kind: DeckCandidateKind) async {
    isExtending = true
    let result = await dealFromPools(seed: seed, kind: kind, count: deckLength)
    applyDealtCandidates(result, appending: true)
    isExtending = false
  }

  private func applyDealtCandidates(_ result: DeckDealResult, appending: Bool) {
    excludeIds.formUnion(result.candidates.map(\.collectionId))
    for candidate in result.candidates where likeCoordinator.isLiked(candidate) {
      likedBeforeSessionIds.insert(candidate.collectionId)
    }
    if appending {
      candidates.append(contentsOf: result.candidates)
    } else {
      candidates = result.candidates
    }
  }

  /// The Refreshing flow (design §4.2/§8): already-swiped/current cards AND any
  /// liked-but-not-yet-swiped card are pinned in place; only truly-unswiped, unliked cards below
  /// the current position regenerate. Deck v2 note: with the blend UI removed nothing currently
  /// calls this — it is retained blend/deal machinery (same pool policy as `deal`), not UI.
  ///
  /// Guarded against re-entrancy via `dealingGate`, shared with `dealMore()` — see that method's
  /// doc comment for why the two share a gate. Crucially, the snapshot
  /// (`currentIndex`/`keptIndexedCandidates`) is computed INSIDE the gate's operation closure,
  /// not before calling `run` — computing it before would reintroduce the exact staleness bug
  /// this guard exists to fix, just gated behind a queue instead of firing concurrently.
  func refresh() async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    var didRefresh = false
    await dealingGate.run(kind: .refresh, ignoreIfSameKindInFlight: false) { [weak self] in
      guard let self else { return }
      guard let snapshot = refreshSnapshot() else { return }
      didRefresh = true
      await performRefresh(
        seed: seed, kind: kind, currentIndex: snapshot.currentIndex,
        replaceCount: snapshot.replaceCount, keptIds: snapshot.keptIds
      )
    }

    // Deliberately outside the gated span above: the banner-visibility timer below doesn't touch
    // `candidates`/`excludeIds`, so it has no need to hold the gate and block a subsequent
    // refresh()/dealMore() call for its own full 1.5s on top of the actual network round trip.
    if didRefresh {
      await showRefreshBannerTransiently()
    }
  }

  private func refreshSnapshot() -> (currentIndex: Int, keptIds: Set<String>, replaceCount: Int)? {
    let currentIndex = candidates.firstIndex(where: { $0.id == scrollPositionId }) ?? 0
    let keptIndexedCandidates = candidates.enumerated().filter { index, candidate in
      index <= currentIndex || likeCoordinator.isLiked(candidate)
    }
    let keptIds = Set(keptIndexedCandidates.map(\.element.id))
    let replaceCount = candidates.count - keptIndexedCandidates.count
    guard replaceCount > 0 else { return nil }
    return (currentIndex, keptIds, replaceCount)
  }

  private func performRefresh(
    seed: DeckSeed,
    kind: DeckCandidateKind,
    currentIndex: Int,
    replaceCount: Int,
    keptIds: Set<String>
  ) async {
    isRefreshing = true
    let result = await dealFromPools(seed: seed, kind: kind, count: replaceCount)
    excludeIds.formUnion(result.candidates.map(\.collectionId))
    for candidate in result.candidates where likeCoordinator.isLiked(candidate) {
      likedBeforeSessionIds.insert(candidate.collectionId)
    }

    candidates = rebuiltCandidates(
      keeping: keptIds,
      afterIndex: currentIndex,
      freshCandidates: result.candidates
    )
    isRefreshing = false
  }

  /// Walks the existing deck in order, keeping pinned cards in place and filling every
  /// non-pinned slot below `currentIndex` with the next fresh candidate; any leftover fresh
  /// candidates (shouldn't normally happen — `replaceCount` was sized to match) are appended.
  private func rebuiltCandidates(
    keeping keptIds: Set<String>,
    afterIndex currentIndex: Int,
    freshCandidates: [DeckCandidate]
  )
    -> [DeckCandidate] {
    var freshQueue = freshCandidates
    var rebuilt: [DeckCandidate] = []
    rebuilt.reserveCapacity(candidates.count)
    for (index, candidate) in candidates.enumerated() {
      if keptIds.contains(candidate.id) {
        rebuilt.append(candidate)
      } else if index > currentIndex, !freshQueue.isEmpty {
        rebuilt.append(freshQueue.removeFirst())
      }
    }
    rebuilt.append(contentsOf: freshQueue)
    return rebuilt
  }

  private func showRefreshBannerTransiently() async {
    refreshBannerVisible = true
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    refreshBannerVisible = false
  }
}
