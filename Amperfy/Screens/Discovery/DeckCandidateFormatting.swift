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

  /// Evidence line templates (design §5.2): adjacency pool → `Close match to "<seed>"`;
  /// similar-songs pool → `A new direction from "<seed>"`; history seed →
  /// `Because you've been playing <artist>`.
  ///
  /// **Integration pass note:** `DeckPool` only ever distinguishes `.adjacency`/`.similar` — a
  /// candidate's *pool* provenance is orthogonal to what *seeded* the deal, so the third template
  /// is selected via `provenance.seedArtist` (only ever non-nil for a `.recentHistory` seed —
  /// see `DeckSeedResolver`), not via `provenance.pool`. This takes priority over the two
  /// pool-based templates whenever it's available; when a `.recentHistory` seed has no resolvable
  /// artist, `seedArtist` is `nil` and this falls back to the pool-based templates (using
  /// `seedTitle`, "your recent listening") rather than fabricating an artist name.
  static func evidenceLine(for provenance: DeckProvenance) -> String {
    if let seedArtist = provenance.seedArtist {
      return "Because you\u{2019}ve been playing \(seedArtist)"
    }
    switch provenance.pool {
    case .adjacency:
      return "Close match to \u{201C}\(provenance.seedTitle)\u{201D}"
    case .similar:
      return "A new direction from \u{201C}\(provenance.seedTitle)\u{201D}"
    }
  }

  /// Live audition readout (design §5.2): "“<track title>” — <artist>".
  static func auditionReadout(title: String, artist: String) -> String {
    "\u{201C}\(title)\u{201D} — \(artist)"
  }
}
