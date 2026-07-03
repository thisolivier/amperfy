@testable import AmperfyKit
import AVFoundation
import XCTest

/// Regression test for a race between `NeedleDropSpritePlayer.stop()` and an in-flight,
/// zero-tolerance seek issued by a prior `seekAndPlay(to:onAudibleStart:)` call.
///
/// ## The bug this guards against
/// `seekAndPlay` issues `AVPlayer.seek(to:toleranceBefore:toleranceAfter:completionHandler:)`
/// with zero tolerance, and its completion handler calls `player.play()` only if
/// `_seekGeneration` still matches the generation captured when the seek was issued (this is
/// how a scrub superseded by a *newer* scrub is correctly discarded). The bug: `stop()` used to
/// pause the player and clear the pending-latency-callback state without bumping
/// `_seekGeneration`. So a seek still in flight when `stop()` fired (realistically
/// tens-to-hundreds of ms for a real audio file, not instantaneous) would complete afterward,
/// still read as "current", and call `player.play()` — silently resuming audio a caller already
/// believed was stopped. The design doc's hard rule (§6: never two audio sources at once) makes
/// this a real bug, not a cosmetic one: the Needle Drop deck's primary interaction is
/// scrub-then-immediately-tap-Play, which calls `stop()` on the sprite player while its seek may
/// still be resolving.
///
/// ## Why this repro is (close to) deterministic, not "hoping timing works out"
/// `seekAndPlay` and `stop()` are both synchronous, non-suspending calls on `@MainActor`. This
/// test calls them back-to-back on the main thread with no `await` in between, so there is no
/// point at which the run loop can service the seek's completion handler (which AVPlayer always
/// invokes asynchronously relative to the `seek(to:...)` call — it is never synchronous inline
/// with that call) between them. That guarantees `stop()`'s generation bump is visible-in-order
/// to the completion handler's later `_seekGeneration` check on the main actor, regardless of how
/// fast or slow the underlying seek turns out to be. The one part of this test that is *not*
/// pinned down by an API contract — and is instead relying on real, observed AVFoundation
/// behavior for a ~9-second local stub file — is that the seek actually completes and, on the
/// old buggy code, actually reaches `.playing` within the fixed wait window below. That part is
/// extremely reliable in practice (tiny local asset, no network), but it is empirical, not
/// guaranteed, so this test is best described as "would have failed almost every run against the
/// old code" rather than "mathematically guaranteed to fail every single run".
@MainActor
final class NeedleDropSpritePlayerStopRaceTest: XCTestCase {
  private var player: AVPlayer!
  private var spritePlayer: NeedleDropSpritePlayer!
  private var timeControlStatusObservation: NSKeyValueObservation?

  override func setUp() {
    super.setUp()
    let manifest = NeedleDropStubFixture.makeManifest()
    player = AVPlayer(url: manifest.spriteURL)
    spritePlayer = NeedleDropSpritePlayer(player: player)
  }

  override func tearDown() {
    timeControlStatusObservation?.invalidate()
    timeControlStatusObservation = nil
    spritePlayer.stop()
    spritePlayer = nil
    player = nil
    super.tearDown()
  }

  /// Scrub-then-immediately-stop: starts a `seekAndPlay`, then calls `stop()` essentially
  /// immediately afterward (before the seek's completion handler could plausibly have run — see
  /// the type-level doc comment above for why that ordering is actually guaranteed here, not just
  /// likely), then waits long enough for the seek to have definitely resolved either way and
  /// asserts playback never resumed.
  func testStopImmediatelyAfterSeekAndPlayDoesNotResumePlayback() {
    let manifest = NeedleDropStubFixture.makeManifest()
    let slice = manifest.slices[2]

    let didResumePlaybackExpectation = expectation(
      description: "player.timeControlStatus should NOT transition to .playing after stop() " +
        "raced an in-flight seek"
    )
    didResumePlaybackExpectation.isInverted = true

    timeControlStatusObservation = player
      .observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
        guard observedPlayer.timeControlStatus == .playing else { return }
        didResumePlaybackExpectation.fulfill()
      }

    // Issue a zero-tolerance seek + play...
    spritePlayer.seekAndPlay(to: slice) { _ in }

    // ...and stop synchronously, on the same run-loop turn, with no suspension point in between.
    // AVPlayer's seek completion handler is always asynchronous relative to the `seek(to:...)`
    // call itself, so this `stop()` is guaranteed to run (and fully complete, including its
    // `_seekGeneration` bump) before that handler's later generation check can observe it.
    spritePlayer.stop()

    // Give the still in-flight seek plenty of time to resolve and, on the old buggy code, call
    // player.play() — a few hundred ms is generous for this ~9s local stub file with no network
    // involved.
    wait(for: [didResumePlaybackExpectation], timeout: 0.6)

    XCTAssertFalse(
      spritePlayer.isPlaying,
      "stop() should have invalidated the in-flight seek's generation so its completion " +
        "handler skips calling player.play()"
    )
    XCTAssertNotEqual(
      player.timeControlStatus,
      .playing,
      "playback should not have resumed after stop() raced an in-flight seek"
    )
  }
}
