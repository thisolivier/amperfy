import AVFoundation
import Foundation

// MARK: - NeedleDropSpritePlayer

/// Plays back manifest slices from a collection's preview-sprite audio file, and measures the
/// touch-to-audible-playback latency of each `seekAndPlay` call.
///
/// One instance owns exactly one `AVPlayer` loaded against a single sprite file, per the design
/// doc's "one AVPlayer per visible card on the local sprite file"
/// (`docs/ux/amperfy-needle-drop-deck-v1-design.md` §5.3). It is a standalone, testable type —
/// not a private implementation detail of `NeedleDropBar` — so the latency-measurement harness
/// (`AmperfyKitTests/Cases/Player/NeedleDropLatencyTest.swift`) can call the exact same
/// `seekAndPlay` entry point the view's gestures use.
///
/// ## What the measured latency actually is
/// `seekAndPlay` captures `t0 = CACurrentMediaTime()` immediately before issuing
/// `AVPlayer.seek(to:toleranceBefore:toleranceAfter:completionHandler:)`. Inside that seek's
/// completion handler (once the seek itself has finished) it calls `player.play()`. Separately,
/// this class KVO-observes `AVPlayer.timeControlStatus`; the moment that property transitions to
/// `.playing`, the stopwatch is read again and the elapsed time is handed to `onAudibleStart`.
///
/// This is **not** a literal touch-to-speaker measurement — there is no way to instrument the
/// audio hardware itself from application code. It is touch-to-"AVPlayer actually reports it
/// started playing", which is the honest, defensible signal available in this environment. It
/// does exercise the real seek + buffer-fill + decode-start pipeline against the on-device
/// AAC decoder, so the resulting number is real, not a mock returning a near-zero placeholder.
@MainActor
public final class NeedleDropSpritePlayer: ObservableObject {
  @Published
  public private(set) var currentSlice: NeedleDropSlice?
  @Published
  public private(set) var isPlaying = false

  private let player: AVPlayer
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?

  /// Fired (with a human-readable reason) if the player item transitions to `.failed` — i.e. the
  /// sprite audio file itself could not be loaded. Used by the deck's audio coordinator to record
  /// the failure into `DiscoveryTelemetry` (build-60: self-diagnosing missing previews).
  public var onItemFailed: ((String) -> ())?

  /// Bumped on every `seekAndPlay` call so a stale seek's completion handler (superseded by a
  /// later scrub) can recognize it is no longer current and avoid calling `play()` out of turn.
  nonisolated(unsafe) private var _seekGeneration = 0
  private let _seekGenerationLock = NSLock()

  private struct PendingAudibleStart {
    let generation: Int
    let startTime: CFTimeInterval
    let callback: (TimeInterval) -> ()
  }

  nonisolated(unsafe) private var _pendingAudibleStart: PendingAudibleStart?
  private let _pendingAudibleStartLock = NSLock()

  /// Loads `spriteURL` into a fresh `AVPlayer`. This is the normal path used by `NeedleDropBar`.
  /// `httpHeaderFields` (e.g. the sidecar-correlation `X-Deal-Id` header) are attached to the
  /// asset's HTTP requests via `AVURLAsset`'s header-fields option when provided.
  public init(spriteURL: URL, httpHeaderFields: [String: String]? = nil) {
    if let httpHeaderFields {
      let asset = AVURLAsset(
        url: spriteURL,
        options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaderFields]
      )
      self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    } else {
      self.player = AVPlayer(url: spriteURL)
    }
    player.automaticallyWaitsToMinimizeStalling = false
    observeTimeControlStatus()
    observeItemStatus()
  }

  /// Wraps an already-constructed `AVPlayer`. Exists for testability (e.g. pointing at a bundled
  /// fixture file) and for previews.
  public init(player: AVPlayer) {
    self.player = player
    player.automaticallyWaitsToMinimizeStalling = false
    observeTimeControlStatus()
    observeItemStatus()
  }

  deinit {
    timeControlStatusObservation?.invalidate()
    itemStatusObservation?.invalidate()
  }

  /// Seeks the sprite to `slice`'s offset and begins playback, reporting the touch-to-audible
  /// latency (in seconds) via `onAudibleStart` once `AVPlayer.timeControlStatus` transitions to
  /// `.playing`. See the type-level doc comment for exactly what this measures.
  public func seekAndPlay(
    to slice: NeedleDropSlice,
    onAudibleStart: @escaping (TimeInterval) -> ()
  ) {
    currentSlice = slice
    let t0 = CACurrentMediaTime()

    let generation = _seekGenerationLock.withLock {
      _seekGeneration += 1
      return _seekGeneration
    }
    _pendingAudibleStartLock.withLock {
      _pendingAudibleStart = PendingAudibleStart(
        generation: generation,
        startTime: t0,
        callback: onAudibleStart
      )
    }

    let targetTime = CMTime(seconds: slice.spriteOffset, preferredTimescale: 600)
    player
      .seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
        guard finished else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          let isCurrent = _seekGenerationLock.withLock { self._seekGeneration == generation }
          guard isCurrent else { return }
          player.play()
        }
      }
  }

  /// Pauses playback in place without clearing `currentSlice`, used by the Riding/AutoAuditioning
  /// -> PausedAudition transition (§3.2).
  ///
  /// Also bumps `_seekGeneration` so a zero-tolerance seek still in flight from a prior
  /// `seekAndPlay` cannot resurrect playback via its completion handler's `player.play()` after
  /// this call returns (same race `stop()` closes; see its doc comment for the full story).
  public func pause() {
    _seekGenerationLock.withLock { _seekGeneration += 1 }
    player.pause()
  }

  /// Resumes playback in place, used by the PausedAudition -> Riding transition (§3.2).
  public func resume() {
    player.play()
  }

  /// Stops playback and discards any in-flight latency callback (e.g. card swiped away).
  ///
  /// Also bumps `_seekGeneration` before pausing. `seekAndPlay` issues a zero-tolerance seek
  /// whose completion handler only calls `player.play()` if `_seekGeneration` still matches the
  /// generation captured at seek-start; without this bump, a seek in flight when `stop()` fires
  /// (realistically tens-to-hundreds of ms for a real audio file) would still be "current" once it
  /// completes and would call `player.play()` after the caller believed playback had stopped —
  /// e.g. resuming a scrub's audio after the deck has already switched to the main player.
  public func stop() {
    _seekGenerationLock.withLock { _seekGeneration += 1 }
    player.pause()
    _pendingAudibleStartLock.withLock { _pendingAudibleStart = nil }
  }

  private func observeItemStatus() {
    itemStatusObservation = player.currentItem?
      .observe(\.status, options: [.new]) { [weak self] observedItem, _ in
        guard observedItem.status == .failed else { return }
        let reason = observedItem.error?.localizedDescription ?? "unknown error"
        Task { @MainActor [weak self] in
          self?.onItemFailed?(reason)
        }
      }
  }

  private func observeTimeControlStatus() {
    timeControlStatusObservation = player
      .observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
        guard observedPlayer.timeControlStatus == .playing else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          isPlaying = true
          let pending = _pendingAudibleStartLock.withLock { () -> PendingAudibleStart? in
            let value = self._pendingAudibleStart
            self._pendingAudibleStart = nil
            return value
          }
          guard let pending else { return }
          let latency = CACurrentMediaTime() - pending.startTime
          pending.callback(latency)
        }
      }
  }
}
