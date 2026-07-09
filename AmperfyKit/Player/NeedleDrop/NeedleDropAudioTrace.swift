import AVFoundation
import Foundation

// MARK: - NeedleDropAudioTrace

//
// Reusable, DEBUG/QA-gated audio-output validation harness for the needle-drop preview player.
//
// PURPOSE
// -------
// The needle-drop preview plays on a bare `AVPlayer` (`NeedleDropSpritePlayer`). Whether that
// player produces NON-SILENT audio cannot be measured from application code by listening to the
// speaker. This harness measures the truth two independent ways:
//
//   1. An `MTAudioProcessingTap` attached to the player item (via an `AVMutableAudioMix` set on
//      the `AVPlayerItem`) computes per-buffer RMS + peak. Non-zero RMS/peak == real, non-silent
//      samples are flowing through the render pipeline. Zero/absent == silent at the source (the
//      player is not really decoding/rendering audio).
//   2. A one-shot state snapshot at play time (rate, timeControlStatus, item status/error, audio
//      track presence + enablement, volume/mute, and the shared AVAudioSession's category/mode/
//      options/outputVolume/isOtherAudioPlaying). This distinguishes "produces no samples" from
//      "produces samples but the route/session/volume silenced them."
//
// Both are written as timestamped lines to a trace file in the app's Documents directory, which is
// the reliable capture channel per the QA knowledge base (no logging stack to fail — read it back
// with `xcrun simctl get_app_container <UDID> dev.thisolivier.amperfy data`).
//
// GATING
// ------
// The entire type is compiled only under DEBUG. Production/release builds never reference it, so
// there is zero release behavior change. `NeedleDropSpritePlayer` guards every call site with
// `#if DEBUG` + an explicit enable flag.

#if DEBUG
  /// Attaches an audio-level tap + writes timestamped RMS/peak/state lines to a Documents trace file.
  /// One instance per preview `AVPlayer`. Not thread-confined beyond what the tap callbacks require;
  /// the tap callbacks run on a media-services thread and append to the file behind a lock.
  public final class NeedleDropAudioTrace {
    /// Default trace filename in the app's Documents directory.
    public static let defaultFileName = "needle-drop-audio-trace.log"

    private let fileURL: URL
    private let writeLock = NSLock()
    private var bufferCount: Int = 0
    private var maxPeakSeen: Float = 0
    private var maxRMSSeen: Float = 0

    public init(fileName: String = NeedleDropAudioTrace.defaultFileName) {
      let documents = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
      self.fileURL = documents.appendingPathComponent(fileName)
      // Truncate any prior run so each session's trace is self-contained.
      try? "".write(to: fileURL, atomically: true, encoding: .utf8)
      line("=== NeedleDropAudioTrace opened ===")
    }

    /// Appends one timestamped line to the trace file.
    public func line(_ text: String) {
      let stamp = ISO8601DateFormatter().string(from: Date())
      let entry = "t=\(stamp) \(text)\n"
      writeLock.lock()
      defer { writeLock.unlock() }
      guard let data = entry.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: fileURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(data)
      } else {
        try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
      }
    }

    /// Snapshot of player + item + session state, taken at `player.play()` time. This is what
    /// distinguishes "no samples produced" from "samples produced but silenced downstream."
    @MainActor
    public func logPlayState(player: AVPlayer, phase: String) {
      let item = player.currentItem
      var audioTrackInfo = "no-currentItem"
      if let item {
        let audioTracks = item.tracks.filter { ($0.assetTrack?.mediaType) == .audio }
        if audioTracks.isEmpty {
          audioTrackInfo = "audioTracks=0 (item.tracks.count=\(item.tracks.count))"
        } else {
          let enabledFlags = audioTracks.map { "\($0.isEnabled)" }.joined(separator: ",")
          audioTrackInfo = "audioTracks=\(audioTracks.count) enabled=[\(enabledFlags)]"
        }
      }
      let itemStatus = item.map { statusString($0.status) } ?? "nil"
      let itemError = item?.error?.localizedDescription ?? "none"
      let session = AVAudioSession.sharedInstance()
      line("""
      STATE[\(phase)] rate=\(player.rate) \
      timeControlStatus=\(timeControlString(player.timeControlStatus)) \
      itemStatus=\(itemStatus) itemError=\(itemError) \
      \(audioTrackInfo) \
      playerVolume=\(player.volume) playerMuted=\(player.isMuted)
      """)
      line("""
      SESSION[\(phase)] category=\(session.category.rawValue) \
      mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) \
      outputVolume=\(session.outputVolume) \
      otherAudioPlaying=\(session.isOtherAudioPlaying)
      """)
    }

    /// Logs a rolling summary of the tap's measured levels so far.
    public func logTapSummary() {
      writeLock.lock()
      let buffers = bufferCount
      let peak = maxPeakSeen
      let rms = maxRMSSeen
      writeLock.unlock()
      line("TAP_SUMMARY buffers=\(buffers) maxRMS=\(rms) maxPeak=\(peak)")
    }

    // MARK: Tap installation

    /// Builds an `AVMutableAudioMix` carrying an `MTAudioProcessingTap` for `assetTrack` that
    /// computes per-buffer RMS + peak and appends them to the trace. Returns nil if the tap could
    /// not be created (logged), in which case the caller should still play — just without level
    /// measurement.
    public func makeAudioMix(for assetTrack: AVAssetTrack) -> AVAudioMix? {
      var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
        init: { _, clientInfo, tapStorageOut in
          tapStorageOut.pointee = clientInfo
        },
        finalize: { tap in
          let storage = MTAudioProcessingTapGetStorage(tap)
          Unmanaged<NeedleDropAudioTrace>.fromOpaque(storage).release()
        },
        prepare: nil,
        unprepare: nil,
        process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
          let status = MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
          )
          guard status == noErr else { return }
          let storage = MTAudioProcessingTapGetStorage(tap)
          let trace = Unmanaged<NeedleDropAudioTrace>.fromOpaque(storage)
            .takeUnretainedValue()
          trace.processAudio(bufferListInOut, frameCount: numberFramesOut.pointee)
        }
      )

      var tap: MTAudioProcessingTap?
      let createStatus = MTAudioProcessingTapCreate(
        kCFAllocatorDefault,
        &callbacks,
        kMTAudioProcessingTapCreationFlag_PostEffects,
        &tap
      )
      guard createStatus == noErr, let createdTap = tap else {
        line("TAP_CREATE_FAILED status=\(createStatus)")
        // makeAudioMix took a +1 retain via passRetained for clientInfo; balance it since no
        // finalize callback will fire.
        Unmanaged.passUnretained(self).release()
        return nil
      }

      let inputParameters = AVMutableAudioMixInputParameters(track: assetTrack)
      inputParameters.audioTapProcessor = createdTap
      let audioMix = AVMutableAudioMix()
      audioMix.inputParameters = [inputParameters]
      line("TAP_INSTALLED trackID=\(assetTrack.trackID)")
      return audioMix
    }

    private func processAudio(
      _ bufferList: UnsafeMutablePointer<AudioBufferList>,
      frameCount: CMItemCount
    ) {
      let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
      var sumSquares: Double = 0
      var peak: Float = 0
      var sampleCount = 0
      for buffer in buffers {
        guard let rawData = buffer.mData else { continue }
        let floatData = rawData.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for index in 0 ..< count {
          let sample = floatData[index]
          let magnitude = abs(sample)
          if magnitude > peak { peak = magnitude }
          sumSquares += Double(sample) * Double(sample)
          sampleCount += 1
        }
      }
      let rms = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0

      writeLock.lock()
      bufferCount += 1
      if peak > maxPeakSeen { maxPeakSeen = peak }
      if rms > maxRMSSeen { maxRMSSeen = rms }
      let shouldLog = bufferCount <= 20 || bufferCount % 25 == 0
      let currentBuffer = bufferCount
      writeLock.unlock()

      if shouldLog {
        line(String(
          format: "TAP rms=%.6f peak=%.6f frames=%d buffers=%d",
          rms, peak, frameCount, currentBuffer
        ))
      }
    }

    // MARK: Formatting helpers

    private func statusString(_ status: AVPlayerItem.Status) -> String {
      switch status {
      case .unknown: return "unknown"
      case .readyToPlay: return "readyToPlay"
      case .failed: return "failed"
      @unknown default: return "unknown(\(status.rawValue))"
      }
    }

    private func timeControlString(_ status: AVPlayer.TimeControlStatus) -> String {
      switch status {
      case .paused: return "paused"
      case .waitingToPlayAtSpecifiedRate: return "waitingToPlay"
      case .playing: return "playing"
      @unknown default: return "unknown(\(status.rawValue))"
      }
    }
  }
#endif
