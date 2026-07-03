import AmperfyKit
import Foundation

// MARK: - DeckCandidateFormatting

/// Pure formatting helpers translating `DeckCandidate`/`DeckProvenance` into the exact display
/// strings `docs/ux/amperfy-needle-drop-deck-v1-design.md` §5.2 specifies. Kept side-effect free
/// and SwiftUI-agnostic. `Text` callers apply `.textCase(.uppercase)` themselves for the kicker
/// (per the design's own component spec), so these return normal-case strings.
enum DeckCandidateFormatting {
  static func kicker(for candidate: DeckCandidate) -> String {
    let duration = durationText(candidate.totalDuration)
    switch candidate.kind {
    case .album:
      let year = candidate.year.map(String.init) ?? "Unknown year"
      return "Album · \(year) · \(duration)"
    case .playlist:
      let trackWord = candidate.trackCount == 1 ? "Track" : "Tracks"
      return "Playlist · \(candidate.trackCount) \(trackWord) · \(duration)"
    }
  }

  static func durationText(_ duration: TimeInterval) -> String {
    let minutes = max(Int(duration / 60), 0)
    return "\(minutes) Min"
  }

  /// Evidence line templates (design §5.2). `DeckPool` — per the exact data-layer interface this
  /// sprint was handed — only distinguishes `.adjacency`/`.similar`; it carries no third "history"
  /// case, and `DeckProvenance` carries no artist field. That means the design doc's third
  /// template ("Because you've been playing <artist>") can never be cleanly derived from the
  /// given interfaces, even when the deck's *seed* was `.recentHistory` — the candidate's
  /// *provenance* is still adjacency-or-similar regardless of what seeded the deal. Per this
  /// sprint's own instruction ("if you can't derive <artist> cleanly... fall back to the
  /// adjacency/similar templates using seedTitle rather than inventing text"), this intentionally
  /// implements only the two pool-based templates.
  static func evidenceLine(for provenance: DeckProvenance) -> String {
    switch provenance.pool {
    case .adjacency:
      return "Close match to \u{201C}\(provenance.seedTitle)\u{201D}"
    case .similar:
      return "A new direction from \u{201C}\(provenance.seedTitle)\u{201D}"
    }
  }

  /// Primary-action label (design §5.2): "Play" with no audition position, or
  /// "Play from “<track>”" once a slice has been auditioned.
  static func primaryActionLabel(auditionedTrackTitle: String?) -> String {
    guard let auditionedTrackTitle else { return "Play" }
    return "Play from \u{201C}\(auditionedTrackTitle)\u{201D}"
  }

  /// Live audition readout (design §5.2): "“<track title>” — <artist>".
  static func auditionReadout(title: String, artist: String) -> String {
    "\u{201C}\(title)\u{201D} — \(artist)"
  }
}
