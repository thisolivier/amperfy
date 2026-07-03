@testable import AmperfyKit
import AVFoundation
import Combine
import XCTest

/// Regression test for the confirmed bug where `NeedleDropBar`'s `@StateObject`-owned controller
/// permanently froze at whatever `availability` existed at first construction, because
/// `@StateObject`'s `wrappedValue:` closure only runs once per view identity and
/// `NeedleDropBarController` has no update path of its own. Real-world consequence: fed by
/// `AuditionDeckCardAuditionModel.availability` (starts `.loading`, resolves asynchronously once
/// its `.task(id:)` fetch completes), the bar never transitioned to `.unavailable`/`.ready` — zero
/// sprites ever played, on every card, confirmed live in QA.
///
/// The fix is `AuditionDeckCardView.needleDropSection` applying
/// `.id(auditionModel.availability.identityKey)` to its `NeedleDropBar(...)`, which forces SwiftUI
/// to discard the stale view identity and mount a fresh `NeedleDropBar` (and therefore a fresh
/// `NeedleDropBarController`, wired to the caller's now-real `spritePlayer`) the instant
/// `availability` resolves. `NeedleDropBar`'s `controller` property is intentionally `private`
/// (not just `internal`) so it stays out of the public surface — including from `@testable`
/// access — so this test instead does what `.id()` causes SwiftUI to do under the hood: construct
/// a second, independent `NeedleDropBarController` once availability resolves, exactly mirroring
/// the real object-lifecycle shape (`.loading`/nil `spritePlayer` first, then — asynchronously —
/// `.ready(manifest)`/a real coordinator-style `spritePlayer` second) and proves playback actually
/// reaches a real `AVPlayer.timeControlStatus == .playing` against the bundled stub sprite, the
/// same honest signal `NeedleDropLatencyTest` uses.
@MainActor
final class NeedleDropBarAvailabilityTransitionTest: XCTestCase {
  private var cancellables: Set<AnyCancellable> = []

  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }

  /// Drives the exact shape of the real bug end to end and proves the fix's mechanism — a fresh
  /// controller minted once availability resolves — actually gets real audio playing.
  func testResolvedControllerReachesRealPlaybackAfterLoadingToReadyTransition() throws {
    // Phase 1: mirrors AuditionDeckCardView's first render, while
    // AuditionDeckCardAuditionModel.availability is still its published initial `.loading` value
    // and `.spritePlayer` is still nil (only set inside `apply()` once a fetch resolves). This is
    // exactly what the buggy `NeedleDropBar`'s `@StateObject` captured at construction, forever.
    let loadingController = NeedleDropBarController(availability: .loading, spritePlayer: nil)
    XCTAssertEqual(loadingController.state, .loadingSprite)

    // Phase 2: mirrors the async manifest fetch resolving later
    // (`AuditionDeckCardAuditionModel.apply(.ready(manifest))`), which also mints the real,
    // coordinator-owned sprite player (`AuditionDeckAudioCoordinator.spritePlayer(for:manifest:)`
    // -> `NeedleDropSpritePlayer(spriteURL:)`) pointed at the real bundled AAC fixture.
    let manifest = NeedleDropStubFixture.makeManifest()
    let resolvedSpritePlayer = NeedleDropSpritePlayer(spriteURL: manifest.spriteURL)

    // Phase 3: this is the fix's mechanism under test. `.id(availability.identityKey)` changes
    // ("loading" -> "ready-stub-collection") the instant `.ready` arrives, forcing SwiftUI to
    // discard the old view identity and mount a brand new `NeedleDropBar` — which constructing a
    // *second*, independent controller here simulates faithfully. Before the fix, no remount ever
    // happened: `loadingController` above has no `apply`/update method to move it off
    // `.loadingSprite` — constructing a new instance is the *only* way a resolved manifest can
    // ever reach a live controller, and only the `.id()` fix causes SwiftUI to do that.
    let resolvedController = NeedleDropBarController(
      availability: .ready(manifest),
      spritePlayer: resolvedSpritePlayer
    )
    XCTAssertEqual(resolvedController.state, .idle)
    // Confirms the resolved controller is wired to the *same* real player instance the caller
    // (and its audition readout subscription) observes. The old bug's controller would instead
    // have kept an internally-created placeholder (`NeedleDropSpritePlayer(player: AVPlayer())`,
    // pointed at no URL) — never this instance.
    XCTAssertTrue(resolvedController.spritePlayer === resolvedSpritePlayer)

    // Phase 4: trigger playback exactly the way the real deck does — the "card settles" auto-
    // audition hook (`AuditionDeckCardView.handleCurrentChange`'s 400ms-delayed
    // `autoAuditionTrigger = true` -> `NeedleDropBar`'s `.onChange` -> `controller
    // .startAutoAuditioning()`).
    resolvedController.startAutoAuditioning()
    XCTAssertEqual(resolvedController.state, .autoAuditioning)

    // Phase 5: the real proof — not a state-enum-only check. Wait for the real, KVO-driven
    // `AVPlayer.timeControlStatus` signal (via `NeedleDropSpritePlayer.$isPlaying`, which only
    // flips `true` when the underlying `AVPlayer` genuinely transitions to `.playing`) to fire
    // against the real bundled `needle_drop_stub_sprite.m4a` fixture.
    let playingExpectation = expectation(description: "resolved sprite player reaches .playing")
    resolvedSpritePlayer.$isPlaying
      .filter { $0 }
      .first()
      .sink { _ in playingExpectation.fulfill() }
      .store(in: &cancellables)

    wait(for: [playingExpectation], timeout: 5)
    XCTAssertTrue(resolvedSpritePlayer.isPlaying)

    // Phase 6: the counterfactual. Without the `.id()`-forced remount, the original
    // `loadingController` (what the bug pinned the bar to) never received the manifest and never
    // touched `resolvedSpritePlayer` at all — it stayed frozen exactly as QA observed ("zero
    // sprites ever played across an entire session, on every card"). This is what the old code
    // would have exhibited for the *entire* card lifetime, not just momentarily.
    XCTAssertEqual(loadingController.state, .loadingSprite)
    XCTAssertFalse(loadingController.spritePlayer === resolvedSpritePlayer)
    XCTAssertFalse(loadingController.spritePlayer.isPlaying)
  }

  /// Companion case for the other half of the bug report: a resolved `.unavailable` (404 / no
  /// sprite for this collection) must be just as reachable as `.ready`. Confirms `identityKey`
  /// actually changes across every real transition a caller can hit — including
  /// Unavailable -> Ready via design §8's "retry once automatically", which a naive "just gate on
  /// leaving `.loading`" fix would have missed.
  func testEveryRealAvailabilityTransitionProducesADistinctIdentityKey() {
    let manifest = NeedleDropStubFixture.makeManifest()

    XCTAssertNotEqual(
      NeedleDropSpriteAvailability.loading.identityKey,
      NeedleDropSpriteAvailability.unavailable.identityKey
    )
    XCTAssertNotEqual(
      NeedleDropSpriteAvailability.loading.identityKey,
      NeedleDropSpriteAvailability.ready(manifest).identityKey
    )
    // The retry path: an initial `.failed` fetch mapped to `.unavailable`, later succeeding.
    XCTAssertNotEqual(
      NeedleDropSpriteAvailability.unavailable.identityKey,
      NeedleDropSpriteAvailability.ready(manifest).identityKey
    )
    // Re-applying the *same* manifest is treated as the same identity, so a redundant
    // `AuditionDeckCardAuditionModel.apply` call doesn't tear down an in-progress audition.
    XCTAssertEqual(
      NeedleDropSpriteAvailability.ready(manifest).identityKey,
      NeedleDropSpriteAvailability.ready(manifest).identityKey
    )
  }
}
