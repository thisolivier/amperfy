//
//  AuditionDeckControllerReentrancyTest.swift
//  AmperfyKitTests
//
//  Regression test for the Discovery-D4 Audition Deck re-entrancy bug: `refresh()` and
//  `dealMore()` on `AuditionDeckController` both mutate `candidates`/`excludeIds`, and neither
//  guarded against a second call landing while the first was still awaiting its own
//  `DeckFusionEngine.deal(...)` round trip. The dangerous case a review found: `dealMore()`
//  completing WHILE a `refresh()` was mid-flight let `refresh()`'s final `candidates` write
//  silently discard `dealMore()`'s appended cards, because `refresh()` snapshotted `candidates`
//  *before* its own `await` and overwrote wholesale with that stale snapshot once its own fetch
//  resolved. The fix (see `AuditionDeckController.swift`/`AuditionDeckController+Dealing.swift`)
//  makes the two share one in-flight slot so neither can run while the other is still working.
//
//  **Why this lives in AmperfyKitTests, and what was checked first:** `AuditionDeckController`
//  is app-target (`Amperfy`) code, and this project has exactly one test target —
//  `AmperfyKitTests` — which on paper only tests `AmperfyKit` (it's the only framework in its
//  "Frameworks" build phase, and every existing file under `Cases/` does
//  `@testable import AmperfyKit`, never `@testable import Amperfy`). Before assuming that made
//  app-target code untestable here, `Amperfy.xcodeproj/project.pbxproj` was inspected directly:
//  `AmperfyKitTests` has an explicit `PBXTargetDependency` on the `Amperfy` target (not just
//  `AmperfyKit`), its Debug/Release configs set `TEST_HOST = ".../Amperfy.app/Amperfy"` (a
//  "hosted by this app" test bundle), and the project-level Debug configuration sets
//  `ENABLE_TESTABILITY = YES` (applies to the `Amperfy` target too, since nothing overrides it
//  per-target) — the standard combination Xcode wires up for a test bundle allowed to
//  `@testable import` its host application, not just the sibling framework its name suggests.
//  There's no `BUNDLE_LOADER` entry, which is the one piece of standard "hosted unit test"
//  wiring that's usually alongside `TEST_HOST`/`TestTargetID`; recent Xcode versions can infer it
//  from the Host Application relationship without a literal build setting, but this could not be
//  confirmed by building (the task this file was written under cannot touch `project.pbxproj` or
//  run `xcodebuild`, and this file itself still needs to be added to `AmperfyKitTests`'s Sources
//  build phase by whoever does the project integration pass — same as every other Discovery-D4
//  file before it). **If it turns out `@testable import Amperfy` does not link from this target,
//  the fallback plan is extracting the re-entrancy guard into a plain, independently-testable type
//  under `AmperfyKit/Discovery/`** — deliberately not done pre-emptively here since it would mean
//  touching a file outside this task's explicit "only touch" list.
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

@testable import Amperfy
@testable import AmperfyKit
import XCTest

// MARK: - AsyncGate

/// Lets a test suspend a fake pool's fetch mid-flight and resume it on command, so a race window
/// is deterministic instead of depending on real timing. `waitForArrival()` lets the test confirm
/// the fetch has actually started (and is now blocked) before proceeding, rather than guessing
/// with a `Task.yield()`/sleep.
private actor AsyncGate {
  private var isOpen = false
  private var hasArrived = false
  private var openWaiters: [CheckedContinuation<Void, Never>] = []
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

  func waitToProceed() async {
    hasArrived = true
    let waiting = arrivalWaiters
    arrivalWaiters.removeAll()
    waiting.forEach { $0.resume() }
    if isOpen { return }
    await withCheckedContinuation { openWaiters.append($0) }
  }

  func waitForArrival() async {
    if hasArrived { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func open() {
    isOpen = true
    let waiting = openWaiters
    openWaiters.removeAll()
    waiting.forEach { $0.resume() }
  }
}

// MARK: - GatedFamiliarPool

/// A `FamiliarPoolProviding` fake whose `fetchCandidates` blocks on an `AsyncGate` until the test
/// releases it, and returns a different, pre-scripted result set on each successive call (so
/// `refresh()`'s fetch and `dealMore()`'s fetch can be told apart without racing to mutate shared
/// state at exactly the right moment). An `actor`, not a plain class with a lock, since
/// `DeckFusionEngine.deal(...)` calls this from a concurrent child task per its own doc comment.
private actor GatedFamiliarPool: FamiliarPoolProviding {
  /// `nonisolated`: a constant reference to another actor is `Sendable` and never reassigned, so
  /// the test can reach it (`familiarPool.gate.open()`/`.waitForArrival()`) without an extra
  /// actor-hop `await` just to read the property itself — only `AsyncGate`'s own methods need
  /// awaiting.
  nonisolated let gate = AsyncGate()
  private var resultsQueue: [[ScoredCandidate]]
  private var callCount = 0

  init(resultsQueue: [[ScoredCandidate]]) {
    self.resultsQueue = resultsQueue
  }

  func fetchCandidates(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  ) async throws
    -> [ScoredCandidate] {
    await gate.waitToProceed()
    defer { callCount += 1 }
    guard callCount < resultsQueue.count else { return [] }
    return Array(resultsQueue[callCount].prefix(count))
  }
}

// MARK: - EmptyAdventurousPool

/// Always reports "legitimately zero matches, not degraded" — the adventurous pool plays no part
/// in this bug (it's synchronous, so it can't be the one left mid-flight), it just needs to not
/// contribute candidates or flag a degraded state so the familiar-pool results above are exactly
/// what ends up in `DeckDealResult.candidates`.
private struct EmptyAdventurousPool: AdventurousPoolProviding {
  func candidates(
    seedSongIds: [String],
    kind: DeckCandidateKind,
    excluding: Set<String>,
    count: Int
  )
    -> (results: [ScoredCandidate], dataAvailable: Bool) {
    ([], true)
  }
}

// MARK: - FakePlayerFacade

/// A do-nothing `PlayerFacade` — `AuditionDeckController.play`/`playShuffled`/`addToQueue` are
/// never exercised by this test (only `refresh()`/`dealMore()` are), so every requirement is a
/// stub. `@MainActor` to match `PlayerFacadeImpl`'s own isolation and this test's controller.
@MainActor
private final class FakePlayerFacade: PlayerFacade {
  var prevQueueCount = 0
  func getPrevQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  func getAllPrevQueueItems() -> [AbstractPlayable] { [] }
  var userQueueCount = 0
  func getUserQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  func getAllUserQueueItems() -> [AbstractPlayable] { [] }
  var nextQueueCount = 0
  func getNextQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  func getAllNextQueueItems() -> [AbstractPlayable] { [] }

  var totalPlayDuration = 0
  var remainingPlayDuration = 0
  var volume: Float = 1
  var isPlaying = false
  func getPlayable(at playerIndex: PlayerIndex) -> AbstractPlayable? { nil }
  var currentlyPlaying: AbstractPlayable?
  var currentMusicItem: AbstractPlayable?
  var currentPodcastItem: AbstractPlayable?
  var currentRadioNowPlaying: RadioNowPlayingInfo?
  var contextName = ""
  var elapsedTime: Double = 0
  var duration: Double = 0
  var isShuffle = false
  func toggleShuffle() {}
  var playbackRate: PlaybackRate = .one
  func setPlaybackRate(_ playbackRate: PlaybackRate) {}
  var repeatMode: RepeatMode = .off
  func setRepeatMode(_ repeatMode: RepeatMode) {}
  var isOfflineMode = false
  var isShouldPauseAfterFinishedPlaying = false
  var isAutoCachePlayedItems = false
  var isPopupBarAllowedToHide = true
  var musicItemCount = 0
  var podcastItemCount = 0
  var playerMode: PlayerMode = .music
  var playType: PlayType?
  var activeStreamingBitrate: StreamingMaxBitratePreference?
  var activeTranscodingFormat: StreamingFormatPreference?
  func setPlayerMode(_ newValue: PlayerMode) {}
  var streamingMaxBitrates = StreamingMaxBitrates()
  func setStreamingMaxBitrates(to streamingMaxBitrates: StreamingMaxBitrates) {}
  var streamingTranscodings = StreamingTranscodings()
  func setStreamingTranscodings(to streamingTranscodings: StreamingTranscodings) {}

  func logout(account: Account) {}

  func insertContextQueue(playables: [AbstractPlayable]) {}
  func appendContextQueue(playables: [AbstractPlayable]) {}
  func insertUserQueue(playables: [AbstractPlayable]) {}
  func appendUserQueue(playables: [AbstractPlayable]) {}
  func insertPodcastQueue(playables: [AbstractPlayable]) {}
  func appendPodcastQueue(playables: [AbstractPlayable]) {}
  func removePlayable(at playerIndex: PlayerIndex) {}
  func movePlayable(from: PlayerIndex, to: PlayerIndex) {}
  func clearUserQueue() {}
  func clearContextQueue() {}
  func clearQueues() {}

  func play() {}
  func play(context: PlayContext) {}
  func playShuffled(context: PlayContext) {}
  func play(playerIndex: PlayerIndex) {}
  func pause() {}
  func togglePlayPause() {}
  func stop() {}
  func playPrevious() {}
  func playPreviousOrReplay() {}
  func playNext() {}
  func skipForward(interval: Double) {}
  func skipBackward(interval: Double) {}
  func seek(toSecond: Double) {}

  let audioAnalyzer = AudioAnalyzer()

  func addNotifier(notifier: MusicPlayable) {}

  func updateEqualizerEnabled(isEnabled: Bool) {}
  func updateEqualizerSetting(eqSetting: EqualizerSetting) {}
  func updateReplayGainEnabled(isEnabled: Bool) {}
}

// MARK: - AuditionDeckControllerReentrancyTest

@MainActor
class AuditionDeckControllerReentrancyTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())

    for id in ["seed-album", "r1", "r2", "r3", "d1", "d2", "e1", "e2-unused"] {
      let album = library.createAlbum(account: account)
      album.id = id
      album.name = id
    }
    library.saveContext()
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: AuditionDeckController.deckLengthDefaultsKey)
  }

  private func candidate(_ id: String) -> DeckCandidate {
    DeckCandidate(
      collectionId: id,
      kind: .album,
      title: id,
      subtitle: nil,
      trackCount: 1,
      totalDuration: 100,
      year: nil,
      provenance: DeckProvenance(pool: .adjacency, seedRef: "seed-album", seedTitle: "Seed Album")
    )
  }

  private func scored(_ id: String) -> ScoredCandidate {
    ScoredCandidate(collectionId: id, kind: .album, score: 1, seedTitle: "Seed Album")
  }

  private func makeController(resultsQueue: [[ScoredCandidate]]) -> (AuditionDeckController, GatedFamiliarPool) {
    let familiarPool = GatedFamiliarPool(resultsQueue: resultsQueue)
    let engine = DeckFusionEngine(
      familiarPool: familiarPool,
      adventurousPool: EmptyAdventurousPool(),
      storage: library
    )
    let likeCoordinator = AuditionDeckLikeCoordinator(storage: library, account: account)
    let controller = AuditionDeckController(
      account: account,
      fusionEngine: engine,
      storage: library,
      player: FakePlayerFacade(),
      likeCoordinator: likeCoordinator,
      initialBlend: 0
    )
    controller.currentSeed = .album(id: "seed-album")
    controller.currentKind = .album
    return (controller, familiarPool)
  }

  /// Returns `true` if `task` finishes before `timeoutNanoseconds` elapses, without blocking
  /// beyond that window either way — lets a test prove a call returned immediately (was ignored)
  /// rather than having actually queued behind something still holding the gate closed.
  private func finishesQuickly(
    _ task: Task<Void, Never>,
    timeoutNanoseconds: UInt64 = 300_000_000
  ) async
    -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask { await task.value; return true }
      group.addTask {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  // MARK: - The confirmed bug: dealMore() completing mid-refresh() must not lose candidates

  /// Reproduces the exact race from the bug report: `refresh()` starts (and is held mid-flight on
  /// its own network round trip), `dealMore()` is kicked off while it's still in flight. Under the
  /// old code, `dealMore()` would run to completion and append its cards, then `refresh()` would
  /// finish and overwrite `candidates` with a snapshot taken before that append — silently
  /// dropping it. With the fix, `dealMore()` must not even start its own fetch until `refresh()`
  /// has fully applied its result, so nothing is ever built from stale state.
  func testDealMoreDuringInFlightRefreshDoesNotLoseCandidates() async {
    UserDefaults.standard.set(2, forKey: AuditionDeckController.deckLengthDefaultsKey)

    let (controller, familiarPool) = makeController(resultsQueue: [
      ["r1", "r2", "r3"].map(scored),
      ["d1", "d2"].map(scored),
    ])
    controller.candidates = ["c1", "c2", "c3", "c4"].map(candidate)
    controller.scrollPositionId = "c1"

    let refreshTask = Task { await controller.refresh() }
    await familiarPool.gate.waitForArrival()
    XCTAssertNotNil(controller.inFlightDealingTask, "refresh() should have claimed the slot before its fetch blocks")

    let dealMoreTask = Task { await controller.dealMore() }
    // Force `dealMoreTask` to actually run its synchronous guard-check (and block on
    // `inFlightDealingTask`, since `refresh()` still holds it) before the gate opens below --
    // without this, nothing guarantees `dealMoreTask` gets scheduled ahead of `refresh()`
    // finishing, which would let the test degrade into two calls that just happen to run
    // sequentially (never actually racing), silently defeating the point of the test.
    await Task.yield()
    await Task.yield()

    await familiarPool.gate.open()
    await refreshTask.value
    await dealMoreTask.value

    XCTAssertEqual(
      controller.candidates.map(\.collectionId),
      ["c1", "r1", "r2", "r3", "d1", "d2"],
      "dealMore()'s appended cards must survive a refresh() that was in flight when it ran — " +
        "this is exactly the case the old unguarded code silently dropped"
    )
    XCTAssertFalse(controller.isRefreshing)
    XCTAssertFalse(controller.isExtending)
    XCTAssertNil(controller.inFlightDealingTask)
  }

  // MARK: - dealMore() vs dealMore(): duplicate tap is ignored, not queued or double-applied

  func testDuplicateDealMoreTapIsIgnoredNotDoubleApplied() async {
    UserDefaults.standard.set(1, forKey: AuditionDeckController.deckLengthDefaultsKey)

    let (controller, familiarPool) = makeController(resultsQueue: [
      ["e1"].map(scored),
      ["e2-unused"].map(scored),
    ])
    controller.candidates = ["c1", "c2"].map(candidate)
    controller.scrollPositionId = "c1"

    let firstTask = Task { await controller.dealMore() }
    await familiarPool.gate.waitForArrival()

    let secondTask = Task { await controller.dealMore() }
    let secondTapWasIgnoredImmediately = await finishesQuickly(secondTask)
    XCTAssertTrue(
      secondTapWasIgnoredImmediately,
      "a duplicate dealMore() call while one is already in flight should return immediately " +
        "(ignored), not queue behind the first and fetch its own results"
    )

    await familiarPool.gate.open()
    await firstTask.value

    XCTAssertEqual(
      controller.candidates.map(\.collectionId),
      ["c1", "c2", "e1"],
      "only the first call's fetch should ever have run"
    )
  }
}
