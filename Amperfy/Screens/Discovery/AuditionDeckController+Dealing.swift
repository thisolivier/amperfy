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
  ///
  /// Guarded against re-entrancy: `dealMore()` and `refresh()` share `inFlightDealingTask`
  /// (declared on `AuditionDeckController`) because both mutate
  /// `candidates`/`excludeIds`/`likedBeforeSessionIds`, and letting either run while the other is
  /// still awaiting its own `fusionEngine.deal(...)` round trip is the confirmed bug this guard
  /// closes: the slower call's eventual `candidates` write would otherwise be built against state
  /// that predates the faster call's own mutation, silently discarding it.
  ///
  /// A same-kind collision (a duplicate "Deal more" tap landing while one is already in flight) is
  /// simply ignored — a second identical tap expresses no "newer intent" a fresh fetch could serve,
  /// and the button is also `.disabled(isExtending || isRefreshing)` at the UI layer for the same
  /// reason (`AuditionDeckBlendPanel.swift`); this is the belt-and-braces version for any other
  /// caller, e.g. `AuditionDeckEndCardView`'s own "Deal more" button, which this sprint's scope
  /// didn't include wiring a disabled state for. A cross-kind collision (`refresh()` is running)
  /// waits instead of cancelling — abandoning `refresh()` mid-flight would risk applying its
  /// pinning logic against half-updated state, so it is simply left to finish first.
  func dealMore() async {
    while let existingTask = inFlightDealingTask {
      if inFlightDealingKind == .dealMore { return }
      await existingTask.value
    }

    guard let seed = currentSeed, let kind = currentKind else { return }

    let task = Task { [weak self] in
      await self?.performDealMore(seed: seed, kind: kind)
    }
    inFlightDealingKind = .dealMore
    inFlightDealingTask = task
    await task.value
    inFlightDealingTask = nil
    inFlightDealingKind = nil
  }

  private func performDealMore(seed: DeckSeed, kind: DeckCandidateKind) async {
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
  ///
  /// Guarded against re-entrancy the same way as `dealMore()` — see that method's doc comment for
  /// why the two share `inFlightDealingTask`. Unlike `dealMore()`, a same-kind collision here does
  /// NOT ignore the newer call: `blend` is a live `@Published` property the slider mutates
  /// directly mid-drag (see the controller's type doc comment), so simply waiting for an in-flight
  /// `refresh()` to finish and only THEN taking a fresh `candidates`/`blend` snapshot already gives
  /// the newest slider position priority — there's no need to cancel the older network round trip
  /// to achieve "the newest blend wins", waiting achieves it for free. Crucially, the snapshot
  /// (`currentIndex`/`keptIndexedCandidates`) is taken AFTER the wait loop below, not before:
  /// taking it before would reintroduce the exact staleness bug this guard exists to fix, just
  /// gated behind a queue instead of firing concurrently.
  func refresh() async {
    while let existingTask = inFlightDealingTask {
      await existingTask.value
    }

    guard let seed = currentSeed, let kind = currentKind else { return }
    let currentIndex = candidates.firstIndex(where: { $0.id == scrollPositionId }) ?? 0

    let keptIndexedCandidates = candidates.enumerated().filter { index, candidate in
      index <= currentIndex || likeCoordinator.isLiked(candidate)
    }
    let keptIds = Set(keptIndexedCandidates.map(\.element.id))
    let replaceCount = candidates.count - keptIndexedCandidates.count
    guard replaceCount > 0 else { return }

    let task = Task { [weak self] in
      await self?.performRefresh(
        seed: seed, kind: kind, currentIndex: currentIndex,
        replaceCount: replaceCount, keptIds: keptIds
      )
    }
    inFlightDealingKind = .refresh
    inFlightDealingTask = task
    await task.value
    inFlightDealingTask = nil
    inFlightDealingKind = nil

    // Deliberately outside the guarded span above: the banner-visibility timer below doesn't touch
    // `candidates`/`excludeIds`, so it has no need to hold the slot and block a subsequent
    // refresh()/dealMore() call for its own full 1.5s on top of the actual network round trip.
    await showRefreshBannerTransiently()
  }

  private func performRefresh(
    seed: DeckSeed,
    kind: DeckCandidateKind,
    currentIndex: Int,
    replaceCount: Int,
    keptIds: Set<String>
  ) async {
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
