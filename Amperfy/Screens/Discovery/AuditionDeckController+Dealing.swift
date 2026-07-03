import AmperfyKit
import Foundation

// MARK: - AuditionDeckController dealing/refresh flow

/// Split out of `AuditionDeckController.swift` to keep both files comfortably under the project's
/// ~200-line convention — this is the deck's whole dealing/refresh/Deal-More flow (design
/// §3.1/§4.2/§8), which is enough logic on its own to earn a file.
extension AuditionDeckController {
  func deal(seed: DeckSeed, kind: DeckCandidateKind, blend: Double) async {
    currentSeed = seed
    currentKind = kind
    self.blend = blend
    lifecycleState = .dealing

    let result = await fusionEngine.deal(
      seed: seed, kind: kind, blend: blend, count: deckLength,
      excludeIds: excludeIds, account: account
    )
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

  /// Re-deals with the same seed/kind as the last `deal(...)` call, optionally at a new blend.
  /// Covers two design §4.2 transitions with one method: Error state's "Retry" (no blend change —
  /// pass `nil`) and Empty state's "slider moved" (`Empty -- slider moved --> Dealing`, a fresh
  /// deal rather than a `refresh()`, since there are no existing candidates to pin/replace).
  func redeal(blend newBlend: Double? = nil) async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    await deal(seed: seed, kind: kind, blend: newBlend ?? blend)
  }

  /// Appends a fresh deal after the current last card (design §5.4/§5.5's "Deal <n> more").
  func dealMore() async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    isExtending = true
    let result = await fusionEngine.deal(
      seed: seed, kind: kind, blend: blend, count: deckLength,
      excludeIds: excludeIds, account: account
    )
    applyDealtCandidates(result, appending: true)
    isExtending = false
  }

  private func applyDealtCandidates(_ result: DeckDealResult, appending: Bool) {
    degradedPools = result.degradedPools
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
  /// the current position regenerate.
  func refresh() async {
    guard let seed = currentSeed, let kind = currentKind else { return }
    let currentIndex = candidates.firstIndex(where: { $0.id == scrollPositionId }) ?? 0

    let keptIndexedCandidates = candidates.enumerated().filter { index, candidate in
      index <= currentIndex || likeCoordinator.isLiked(candidate)
    }
    let keptIds = Set(keptIndexedCandidates.map(\.element.id))
    let replaceCount = candidates.count - keptIndexedCandidates.count
    guard replaceCount > 0 else { return }

    isRefreshing = true
    let result = await fusionEngine.deal(
      seed: seed, kind: kind, blend: blend, count: replaceCount,
      excludeIds: excludeIds, account: account
    )
    degradedPools = result.degradedPools
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
    await showRefreshBannerTransiently()
  }

  /// Walks the existing deck in order, keeping pinned cards in place and filling every
  /// non-pinned slot below `currentIndex` with the next fresh candidate; any leftover fresh
  /// candidates (shouldn't normally happen — `replaceCount` was sized to match) are appended.
  private func rebuiltCandidates(
    keeping keptIds: Set<String>,
    afterIndex currentIndex: Int,
    freshCandidates: [DeckCandidate]
  ) -> [DeckCandidate] {
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
