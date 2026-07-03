@testable import AmperfyKit
import AVFoundation
import XCTest

/// D3a risk probe: measures real, on-device/simulator touch-to-audible-playback latency for the
/// Needle Drop bar's slice playback, to inform the go/no-go judgment call on the <150ms
/// kill-condition (that judgment itself is explicitly NOT made here — see the note on
/// `testSeekAndPlayLatencyAcross20Trials` below).
///
/// This drives `NeedleDropSpritePlayer.seekAndPlay` directly against the bundled stub sprite
/// fixture (`NeedleDropStubFixture`) rather than simulating a SwiftUI finger-drag on
/// `NeedleDropBar`: there is no reliable way to simulate real touch-drag gesture events with the
/// timing fidelity this measurement needs from an XCTest target. `seekAndPlay` is the exact same
/// entry point the view's gestures call on touch-down and on every segment-boundary crossing, so
/// measuring it directly is the honest, defensible thing to do here — and it isolates exactly the
/// risk this sprint exists to probe (AVPlayer seek + decode-start latency), not SwiftUI
/// gesture-recognition overhead, which is negligible by comparison.
@MainActor
final class NeedleDropLatencyTest: XCTestCase {
  private var spritePlayer: NeedleDropSpritePlayer!
  private var manifest: NeedleDropManifest!

  private static let resultsFilePath =
    "/private/tmp/claude-501/-Users-olivier-sites-musicLibrary/c27a1d1c-0cd5-4a08-953b-1f849955c017/scratchpad/needle-drop-latency-results.json"

  override func setUp() {
    super.setUp()
    manifest = NeedleDropStubFixture.makeManifest()
    // One AVPlayer for the whole trial run, matching the design's "one AVPlayer per visible
    // card" — repeated seekAndPlay calls here mimic scrubbing across segment boundaries on a
    // single card, which is the real usage this sprint needs to probe.
    let player = AVPlayer(url: manifest.spriteURL)
    spritePlayer = NeedleDropSpritePlayer(player: player)
  }

  override func tearDown() {
    spritePlayer.stop()
    spritePlayer = nil
    manifest = nil
    super.tearDown()
  }

  /// Runs 20 timed `seekAndPlay` trials cycling through the 6 stub slices, records each latency
  /// in milliseconds, prints the sorted list + min/median/max, and writes the full results to
  /// `resultsFilePath` as JSON so the numbers survive outside a truncated xcodebuild log tail.
  ///
  /// Deliberately does NOT assert a hard pass/fail threshold against the 150ms target — whether
  /// these numbers constitute a pass is a judgment call for the Team PM/Director/Board, not
  /// something that should silently gate CI. The only assertion here is a sanity check that the
  /// harness actually produced 20 real measurements.
  func testSeekAndPlayLatencyAcross20Trials() throws {
    let trialCount = 20
    var latenciesMs: [Double] = []

    for trialIndex in 0 ..< trialCount {
      let slice = manifest.slices[trialIndex % manifest.slices.count]

      // Force a real .paused -> .playing transition for every trial. `AVPlayer.timeControlStatus`
      // only emits a fresh KVO notification when the value actually *changes* — if the previous
      // trial left the player already `.playing`, a bare re-seek-and-play can leave the status
      // sitting at `.playing` throughout, so the observer never re-fires for that trial and the
      // measured "latency" ends up reflecting an unrelated, coincidental later transition instead
      // (this was caught empirically: without the pause below, most trials read implausibly near
      // 0ms with a handful of large outliers — a measurement artifact, not real latency). Pausing
      // first guarantees each trial starts from a genuine non-playing state, so the `.playing`
      // transition `seekAndPlay` waits on is always freshly caused by that trial's own touch-down,
      // matching the real-world case the 150ms budget is actually about: touch-down onto a bar
      // that isn't already mid-playback.
      spritePlayer.pause()

      let audibleStartExpectation =
        expectation(description: "audible start for trial \(trialIndex)")

      spritePlayer.seekAndPlay(to: slice) { latencySeconds in
        latenciesMs.append(latencySeconds * 1000)
        audibleStartExpectation.fulfill()
      }

      wait(for: [audibleStartExpectation], timeout: 5)
    }

    XCTAssertEqual(latenciesMs.count, trialCount, "expected one recorded latency per trial")

    let sortedMs = latenciesMs.sorted()
    let summary = LatencySummary(
      min: sortedMs.first ?? 0,
      median: median(ofSorted: sortedMs),
      max: sortedMs.last ?? 0,
      n: sortedMs.count
    )

    print("NeedleDrop latency trials (ms, sorted): \(sortedMs)")
    print(
      "NeedleDrop latency summary: min=\(summary.min)ms median=\(summary.median)ms " +
        "max=\(summary.max)ms n=\(summary.n)"
    )

    try writeResults(rawLatenciesMs: latenciesMs, summary: summary)
  }

  private func median(ofSorted sortedValues: [Double]) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    let count = sortedValues.count
    if count % 2 == 1 {
      return sortedValues[count / 2]
    }
    return (sortedValues[count / 2 - 1] + sortedValues[count / 2]) / 2
  }

  private struct LatencySummary {
    let min: Double
    let median: Double
    let max: Double
    let n: Int
  }

  private struct LatencyResultsDocument: Encodable {
    let trialsMs: [Double]
    let min: Double
    let median: Double
    let max: Double
    let n: Int

    enum CodingKeys: String, CodingKey {
      case trialsMs = "trials_ms"
      case min, median, max, n
    }
  }

  private func writeResults(rawLatenciesMs: [Double], summary: LatencySummary) throws {
    let resultsURL = URL(fileURLWithPath: Self.resultsFilePath)
    try FileManager.default.createDirectory(
      at: resultsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let document = LatencyResultsDocument(
      trialsMs: rawLatenciesMs,
      min: summary.min,
      median: summary.median,
      max: summary.max,
      n: summary.n
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document)
    try data.write(to: resultsURL, options: .atomic)

    print("NeedleDrop latency results written to \(Self.resultsFilePath)")
  }
}
