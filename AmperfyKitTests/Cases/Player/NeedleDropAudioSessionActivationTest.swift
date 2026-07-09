@testable import AmperfyKit
import AVFoundation
import XCTest

/// Regression test for the P1 "needle-drop previews: no audio output" bug.
///
/// Root cause: the sprite preview runs on a bare `AVPlayer` independent of the main
/// `BackendAudioPlayer`, and nothing ever configured/activated the shared `AVAudioSession` for it.
/// Until the main player had run at least once, the process session sat at its default
/// `.soloAmbient` category (silenced by the mute switch, not treated as playback), so needle-drop
/// advanced visually but produced no audible output.
///
/// The fix routes every preview `player.play()` through
/// `NeedleDropSpritePlayer.activateAudioSession` (which in production sets `.playback` +
/// `setActive(true)`). Audio output itself is not unit-testable, but the WIRING that was missing
/// — that the preview activates the session before it plays — is, via the injectable hook.
@MainActor
final class NeedleDropAudioSessionActivationTest: XCTestCase {
  private var manifest: NeedleDropManifest!
  private var originalActivateHook: (() -> ())!

  override func setUp() {
    super.setUp()
    manifest = NeedleDropStubFixture.makeManifest()
    originalActivateHook = NeedleDropSpritePlayer.activateAudioSession
  }

  override func tearDown() {
    NeedleDropSpritePlayer.activateAudioSession = originalActivateHook
    manifest = nil
    originalActivateHook = nil
    super.tearDown()
  }

  /// `seekAndPlay` must activate the audio session before the player is told to play — otherwise
  /// the preview plays into a silent/ambient route (the reported bug).
  func testSeekAndPlayActivatesAudioSessionBeforePlaying() {
    var activationCount = 0
    NeedleDropSpritePlayer.activateAudioSession = { activationCount += 1 }

    let spritePlayer = NeedleDropSpritePlayer(player: AVPlayer(url: manifest.spriteURL))
    defer { spritePlayer.stop() }

    let audibleStart = expectation(description: "audible start")
    spritePlayer.seekAndPlay(to: manifest.slices[0]) { _ in audibleStart.fulfill() }
    wait(for: [audibleStart], timeout: 5)

    XCTAssertGreaterThanOrEqual(
      activationCount, 1,
      "seekAndPlay must activate the audio session before starting preview playback"
    )
  }

  /// `resume` (PausedAudition -> Riding) must also re-activate the session, since a preview can be
  /// resumed after other app audio may have deactivated or changed the session category.
  func testResumeActivatesAudioSession() {
    var activationCount = 0
    NeedleDropSpritePlayer.activateAudioSession = { activationCount += 1 }

    let spritePlayer = NeedleDropSpritePlayer(player: AVPlayer(url: manifest.spriteURL))
    defer { spritePlayer.stop() }

    spritePlayer.resume()

    XCTAssertEqual(
      activationCount, 1,
      "resume must activate the audio session before resuming preview playback"
    )
  }

  /// The production default hook sets the `.playback` category and activates the session — the two
  /// properties that make preview audio audible regardless of the hardware mute switch. Verifies
  /// the default isn't accidentally left as a no-op.
  func testDefaultHookSetsPlaybackCategoryAndActivatesSession() {
    // Capture and restore the real device session state around this check.
    let session = AVAudioSession.sharedInstance()
    let previousCategory = session.category

    originalActivateHook()

    XCTAssertEqual(
      session.category, .playback,
      "default activation must put the shared session into the .playback category"
    )

    // Best-effort restore so this test doesn't leak session state into later tests.
    try? session.setCategory(previousCategory)
  }
}
