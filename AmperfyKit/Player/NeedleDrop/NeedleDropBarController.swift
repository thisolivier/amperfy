import AVFoundation
import Foundation
import SwiftUI

// MARK: - NeedleDropBarAuditionState

/// States of the Needle Drop bar per the interaction state diagram
/// (`docs/ux/amperfy-needle-drop-deck-v1-design.md` §3.2).
public enum NeedleDropBarAuditionState: Equatable, Sendable {
  case loadingSprite
  case unavailable
  case idle
  case autoAuditioning
  case scrubbing
  case riding
  case pausedAudition
  case stopped
}

// MARK: - NeedleDropSpriteAvailability

/// How a `NeedleDropBar` was told its sprite currently stands. `.ready` is the normal path (a
/// manifest is already in hand); `.loading`/`.unavailable` let the control render those two
/// states correctly on its own — no fetch pipeline exists yet in this sprint (no deck/card owns
/// that), so callers construct this directly rather than the bar performing a network fetch.
public enum NeedleDropSpriteAvailability {
  case loading
  case unavailable
  case ready(NeedleDropManifest)
}

extension NeedleDropSpriteAvailability {
  /// Stable per-state identity a caller can key a SwiftUI `.id(...)` modifier on so a
  /// `NeedleDropBar`'s `@StateObject`-owned `NeedleDropBarController` gets rebuilt from scratch
  /// whenever `availability` meaningfully changes case, instead of freezing at whatever snapshot
  /// existed when the bar was first constructed — `@StateObject`'s `wrappedValue:` closure only
  /// ever runs once per view identity, and `NeedleDropBarController` has no update path of its
  /// own (`availability`/`spritePlayer` are only ever consumed in `init`). This covers every real
  /// transition a caller can hit: Loading -> Unavailable, Loading -> Ready, and — because a
  /// failed fetch can retry once and later succeed — Unavailable -> Ready too. Two `.ready`
  /// values for the same collection compare equal so a redundant re-apply of an identical
  /// manifest doesn't tear down an in-progress audition. See `NeedleDropBar`'s doc comment and
  /// `AuditionDeckCardView.needleDropSection` for the reference caller usage.
  public var identityKey: String {
    switch self {
    case .loading:
      return "loading"
    case .unavailable:
      return "unavailable"
    case let .ready(manifest):
      return "ready-\(manifest.collectionId)"
    }
  }
}

// MARK: - NeedleDropBarController

/// Owns the Needle Drop bar's interaction state machine and drives slice-to-slice playback via a
/// `NeedleDropSpritePlayer`. Kept separate from the `NeedleDropBar` view so the view stays a thin
/// rendering + gesture layer, and so the state machine can be reasoned about (and unit tested)
/// independently of SwiftUI.
///
/// Riding/auto-auditioning advance from one slice to the next is driven by a `Timer` scheduled
/// for the current slice's `sliceDuration` — a stub-level "good enough" mechanism per the
/// sprint's own instructions; a production version would likely drive this from `AVPlayer`
/// boundary-time observers instead.
@MainActor
final class NeedleDropBarController: ObservableObject {
  @Published
  private(set) var state: NeedleDropBarAuditionState
  @Published
  private(set) var currentSliceIndex: Int = 0
  @Published
  var scrubX: CGFloat?

  let manifest: NeedleDropManifest?
  let spritePlayer: NeedleDropSpritePlayer

  /// Drag distance (points) below which a `DragGesture` end is treated as a tap rather than a
  /// scrub. Not spec'd precisely by the design doc; 8pt matches common UIKit/SwiftUI tap-slop.
  private static let tapDistanceThreshold: CGFloat = 8

  private var rideTimer: Timer?
  private var rideRemainingDurationWhenPaused: TimeInterval?
  private var stateBeforeCurrentTouch: NeedleDropBarAuditionState = .idle

  init(availability: NeedleDropSpriteAvailability, spritePlayer: NeedleDropSpritePlayer? = nil) {
    switch availability {
    case .loading:
      self.manifest = nil
      self.state = .loadingSprite
      self.spritePlayer = spritePlayer ?? NeedleDropSpritePlayer(player: AVPlayer())
    case .unavailable:
      self.manifest = nil
      self.state = .unavailable
      self.spritePlayer = spritePlayer ?? NeedleDropSpritePlayer(player: AVPlayer())
    case let .ready(readyManifest):
      self.manifest = readyManifest
      self.state = .idle
      self.spritePlayer = spritePlayer ?? NeedleDropSpritePlayer(spriteURL: readyManifest.spriteURL)
    }
  }

  var slices: [NeedleDropSlice] { manifest?.slices ?? [] }

  /// Maps a touch/drag x position (within a bar of `barWidth`) to the slice index under it.
  func sliceIndex(atX x: CGFloat, barWidth: CGFloat) -> Int {
    guard !slices.isEmpty, barWidth > 0 else { return 0 }
    let clampedX = min(max(x, 0), barWidth)
    let fraction = clampedX / barWidth
    let index = Int(fraction * CGFloat(slices.count))
    return min(max(index, 0), slices.count - 1)
  }

  /// Programmatic trigger for the Ready -> AutoAuditioning transition. No parent "card settles"
  /// event exists yet (no deck in this sprint) — this is the hook D4 will call.
  func startAutoAuditioning() {
    guard state == .idle, !slices.isEmpty else { return }
    state = .autoAuditioning
    startRiding(fromIndex: 0, ridingState: .autoAuditioning)
  }

  // MARK: Gesture handling

  func handleDragChanged(x: CGFloat, barWidth: CGFloat, isFirstEvent: Bool) {
    guard !slices.isEmpty else { return }
    if isFirstEvent {
      stateBeforeCurrentTouch = state
      // A touch-down while paused doesn't reseek/replay per the state diagram (only "tap again"
      // resumes) — wait for onEnded to decide tap-to-resume vs. a real drag-to-scrub instead.
      guard state != .pausedAudition else { return }
      cancelRide()
      state = .scrubbing
      scrubX = x
      playSlice(at: sliceIndex(atX: x, barWidth: barWidth), fireHaptic: false)
      return
    }
    guard state == .scrubbing else { return }
    scrubX = x
    let index = sliceIndex(atX: x, barWidth: barWidth)
    if index != currentSliceIndex {
      playSlice(at: index, fireHaptic: true)
    }
  }

  func handleDragEnded(translationDistance: CGFloat, x: CGFloat, barWidth: CGFloat) {
    guard !slices.isEmpty else { return }
    scrubX = nil
    let wasTap = translationDistance < Self.tapDistanceThreshold

    if wasTap, stateBeforeCurrentTouch == .riding || stateBeforeCurrentTouch == .autoAuditioning {
      pauseAudition()
      return
    }
    if wasTap, stateBeforeCurrentTouch == .pausedAudition {
      resumeAudition()
      return
    }
    if stateBeforeCurrentTouch == .pausedAudition {
      // Was a real drag starting from paused: behave like a fresh touch-down at the release
      // point's start, i.e. scrub then ride.
      playSlice(at: sliceIndex(atX: x, barWidth: barWidth), fireHaptic: false)
    }
    startRiding(fromIndex: currentSliceIndex, ridingState: .riding)
  }

  // MARK: Playback sequencing

  private func playSlice(at index: Int, fireHaptic: Bool) {
    guard slices.indices.contains(index) else { return }
    currentSliceIndex = index
    if fireHaptic {
      UISelectionFeedbackGenerator().selectionChanged()
    }
    spritePlayer.seekAndPlay(to: slices[index]) { _ in
      // View-facing latency isn't consumed here; the harness calls seekAndPlay directly.
    }
  }

  private func pauseAudition() {
    cancelRide()
    spritePlayer.pause()
    state = .pausedAudition
  }

  private func resumeAudition() {
    spritePlayer.resume()
    state = .riding
    scheduleNextAdvance(
      after: rideRemainingDurationWhenPaused ?? slices[safe: currentSliceIndex]?
        .sliceDuration ?? 0
    )
    rideRemainingDurationWhenPaused = nil
  }

  private func startRiding(fromIndex index: Int, ridingState: NeedleDropBarAuditionState) {
    guard slices.indices.contains(index) else {
      state = .stopped
      return
    }
    state = ridingState
    playSlice(at: index, fireHaptic: false)
    scheduleNextAdvance(after: slices[index].sliceDuration)
  }

  private func scheduleNextAdvance(after duration: TimeInterval) {
    cancelRide()
    guard duration > 0 else { return }
    rideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let nextIndex = currentSliceIndex + 1
        guard slices.indices.contains(nextIndex) else {
          state = .stopped
          spritePlayer.stop()
          return
        }
        startRiding(
          fromIndex: nextIndex,
          ridingState: state == .autoAuditioning ? .autoAuditioning : .riding
        )
      }
    }
  }

  private func cancelRide() {
    rideTimer?.invalidate()
    rideTimer = nil
  }

  /// Card swiped away / view disappeared: stop audio and audition state synchronously.
  func stop() {
    cancelRide()
    spritePlayer.stop()
    state = .stopped
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
