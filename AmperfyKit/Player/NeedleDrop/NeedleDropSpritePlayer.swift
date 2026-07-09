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

  #if DEBUG
    /// DEBUG/QA-only audio-output validation harness. Nil unless a QA/debug caller opts in via
    /// `enableAudioTrace()`. When set, an `MTAudioProcessingTap` measures per-buffer RMS/peak and
    /// play-time player/session state is written to a Documents trace file. Never referenced in
    /// release builds (whole block is `#if DEBUG`), so it cannot affect production behavior.
    private var audioTrace: NeedleDropAudioTrace?
    /// Set once the tap has been installed on the current item, so we don't install it twice.
    private var audioTraceMixInstalled = false

    /// Opt in to audio-output validation for this player (DEBUG/QA only). Idempotent. The tap is
    /// installed against the item's audio track as soon as the item reaches `.readyToPlay` (when
    /// `tracks` is populated); state is logged at each `play()`.
    public func enableAudioTrace(fileName: String = NeedleDropAudioTrace.defaultFileName) {
      guard audioTrace == nil else { return }
      audioTrace = NeedleDropAudioTrace(fileName: fileName)
      audioTrace?.line("ENABLE audioTrace on NeedleDropSpritePlayer")
      installAudioTapIfReady()
    }

    /// Installs the level tap once the current item exposes its audio track. Safe to call multiple
    /// times; no-ops until an audio asset track is available and after it has installed once.
    private func installAudioTapIfReady() {
      guard let audioTrace, !audioTraceMixInstalled, let item = player.currentItem else { return }
      // The item's `tracks` (AVPlayerItemTrack) populate around readyToPlay; for the asset track we
      // need for the mix, load it from the asset. Use the already-loaded tracks when present.
      let audioAssetTracks = item.tracks.compactMap { $0.assetTrack }
        .filter { $0.mediaType == .audio }
      guard let audioAssetTrack = audioAssetTracks.first else { return }
      if let mix = audioTrace.makeAudioMix(for: audioAssetTrack) {
        item.audioMix = mix
        audioTraceMixInstalled = true
      }
    }
  #endif

  /// Fired (with a human-readable reason) if the player item transitions to `.failed` — i.e. the
  /// sprite audio file itself could not be loaded. Used by the deck's audio coordinator to record
  /// the failure into `DiscoveryTelemetry` (build-60: self-diagnosing missing previews).
  public var onItemFailed: ((String) -> ())?

  /// Activates the shared `AVAudioSession` for audible preview playback, called immediately before
  /// every `player.play()` on the preview's own `AVPlayer`.
  ///
  /// This exists because the sprite preview runs on a bare `AVPlayer` that is completely
  /// independent of the main `BackendAudioPlayer` — the main player is the only thing that ever
  /// set the session to `.playback` and activated it (`BackendAudioPlayer.insert`). Until the user
  /// had started real playback at least once in the session, the process audio session sat at its
  /// default `.soloAmbient` category, which is silenced by the hardware mute switch and does not
  /// mix as playback — so needle-drop advanced visually but produced NO audible output (the P1
  /// "needle-drop previews: no audio" bug). Setting `.playback` + `setActive(true)` here makes the
  /// preview audible regardless of the mute switch and regardless of whether the main player has
  /// ever run this session.
  ///
  /// Injectable (a `static var`) so unit tests can replace it with a no-op — activating a real
  /// `AVAudioSession` from the XCTest host is both unnecessary for the wiring under test and
  /// undesirable side-effecting in the test runner. Production callers leave the default in place.
  nonisolated(unsafe) public static var activateAudioSession: () -> () = {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Deliberately swallowed: a session-activation failure must not crash the deck. Playback
      // will simply remain silent, which is no worse than the pre-fix behavior.
    }
  }

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
          Self.activateAudioSession()
          #if DEBUG
            installAudioTapIfReady()
            audioTrace?.logPlayState(player: player, phase: "before-play")
          #endif
          player.play()
          #if DEBUG
            audioTrace?.logPlayState(player: player, phase: "after-play-call")
          #endif
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
    Self.activateAudioSession()
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
        #if DEBUG
          Task { @MainActor [weak self] in
            guard let self else { return }
            let statusName: String
            switch observedItem.status {
            case .unknown: statusName = "unknown"
            case .readyToPlay: statusName = "readyToPlay"
            case .failed: statusName = "failed"
            @unknown default: statusName = "unknown(\(observedItem.status.rawValue))"
            }
            let errorText = observedItem.error.map { error -> String in
              let nsError = error as NSError
              return "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
            } ?? "none"
            audioTrace?.line("ITEM_STATUS -> \(statusName) error=\(errorText)")
            if observedItem.status == .readyToPlay {
              installAudioTapIfReady()
            }
          }
        #endif
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
          #if DEBUG
            audioTrace?.logPlayState(player: player, phase: "reached-playing")
            audioTrace?.logTapSummary()
          #endif
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
