import AmperfyKit
import AVFoundation
import Foundation
import OSLog

// MARK: - NeedleDropDebugAutostart

//
// DEBUG/QA-only programmatic trigger that starts a real needle-drop preview so the audio-output
// validation harness (`NeedleDropAudioTrace`) can measure whether it produces non-silent audio.
//
// WHY THIS EXISTS
// ---------------
// The needle-drop DECK cannot be reached by simulator UI automation (see
// `docs/qa/qa-knowledge-base.md` — the "Find similar albums" UIMenu won't pop via idb tap, the
// Home "Find more" entry has a SwiftUI-in-UIKit hit-test mismatch, and there is no deck deep-link).
// So there is no way to make the preview actually play from a script. This trigger closes that gap
// by driving the exact same production code path — a bare `AVPlayer` inside `NeedleDropSpritePlayer`
// loaded against a real sprite-audio URL, played via `seekAndPlay` (which calls
// `activateAudioSession()` then `player.play()`, precisely as the deck does through
// `NeedleDropBarController.playSlice`).
//
// USAGE (DEBUG builds only)
// -------------------------
//   -NeedleDropDebugAutostart <absolute-sprite-audio-URL>
//
// e.g. `-NeedleDropDebugAutostart http://localhost:8788/sprite-audio?collectionId=<id>&kind=album`
//
// The trigger enables the audio trace, seeks to offset 0, and plays. The trace is written to the
// app's Documents directory (`needle-drop-audio-trace.log`), read back with
// `xcrun simctl get_app_container <UDID> dev.thisolivier.amperfy data`.
//
// The whole file is `#if DEBUG`, so release builds never contain it.

#if DEBUG
  @MainActor
  public enum NeedleDropDebugAutostart {
    public static let launchArgumentName = "-NeedleDropDebugAutostart"

    private static let log = OSLog(
      subsystem: "dev.thisolivier.amperfy",
      category: "NeedleDropDebugAutostart"
    )

    /// Strong reference so the player + its KVO observers survive the async play window (the trigger
    /// is fire-and-forget from `sceneDidBecomeActive`).
    private static var retainedPlayer: NeedleDropSpritePlayer?

    /// Reads the launch argument and, if present, starts a preview against the given sprite URL.
    /// No-ops silently when the argument is absent (the normal app path).
    public static func runIfRequested() {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: launchArgumentName),
            index + 1 < arguments.count else { return }
      let spriteURLString = arguments[index + 1]
      guard let spriteURL = URL(string: spriteURLString), spriteURL.scheme != nil else {
        os_log(
          "NeedleDropDebugAutostart: bad/relative sprite URL %{public}@",
          log: log, type: .error, spriteURLString
        )
        return
      }
      start(spriteURL: spriteURL)
    }

    /// Constructs the sprite player, enables the audio trace, and plays a slice at offset 0. Exposed
    /// (not just called from `runIfRequested`) so a future hidden debug-menu action can reuse it.
    public static func start(spriteURL: URL, offsetSeconds: TimeInterval = 0) {
      os_log(
        "NeedleDropDebugAutostart: starting preview for %{public}@",
        log: log, type: .info, spriteURL.absoluteString
      )
      let player = NeedleDropSpritePlayer(spriteURL: spriteURL)
      player.enableAudioTrace()
      player.onItemFailed = { reason in
        os_log(
          "NeedleDropDebugAutostart: item FAILED: %{public}@",
          log: log, type: .error, reason
        )
      }
      retainedPlayer = player

      // A synthetic slice at offset 0 with a generous duration — the debug run just needs the player
      // to actually play; slice metadata beyond offset/duration is unused by `seekAndPlay`.
      let slice = NeedleDropSlice(
        trackId: "debug-autostart",
        title: "Debug Autostart",
        artist: "QA",
        spriteOffset: offsetSeconds,
        sliceDuration: 30
      )
      player.seekAndPlay(to: slice) { latency in
        os_log(
          "NeedleDropDebugAutostart: reached audible-start, latency=%.3f",
          log: log, type: .info, latency
        )
      }

      // Keep it playing long enough for the tap to accumulate buffers, then stop cleanly so the trace
      // captures a bounded, self-contained run.
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        player.stop()
        os_log("NeedleDropDebugAutostart: stopped after 8s", log: log, type: .info)
      }
    }
  }
#endif
