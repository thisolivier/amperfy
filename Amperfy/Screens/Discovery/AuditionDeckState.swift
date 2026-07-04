import AmperfyKit
import Foundation

// MARK: - AuditionDeckLifecycleState

/// The Audition Deck lifecycle per `docs/ux/amperfy-needle-drop-deck-v1-design.md` §4.2.
///
/// The design's own state diagram has 6 states (Dealing/Populated/Empty/Error/Refreshing/
/// Extended), but its Notes explicitly allow modeling Refreshing/Extended as sub-flags on
/// Populated rather than exclusive cases "if that's cleaner for your SwiftUI bindings" — they are
/// here: both are always reached *from* and *return to* Populated, so `AuditionDeckController`
/// keeps this 4-case lifecycle enum and layers `isRefreshing`/`isExtending` transient flags on
/// top. `AuditionDeckUIState` (below) reconstitutes the full 6-case view for the view layer to
/// switch on, so nothing about "which of the 6 states are we in" is lost — it's just not
/// represented as one flat enum internally.
enum AuditionDeckLifecycleState: Equatable {
  case dealing
  case populated
  case empty
  case error(message: String)
}

// MARK: - AuditionDeckUIState

/// View-facing reconstruction of all 6 states in the design doc's §4.2 diagram. Only
/// `AuditionDeckView` (and previews/tests) should need this type; the controller itself reasons
/// in terms of `AuditionDeckLifecycleState` + the transient flags.
enum AuditionDeckUIState: Equatable {
  case dealing
  case populated
  case refreshing
  case extended
  case empty
  case error(message: String)
}

// MARK: - AuditionDeckDegradedPoolMessage

/// Partial-degradation handling (design §8, Deck v2): one pool unreachable is NOT the Error
/// state — the deck silently falls back to the other pool (no warning chip UI anymore); only
/// both pools down reaches Error.
enum AuditionDeckDegradedPoolMessage {
  /// `DeckPool` (per the exact data-layer interface this sprint was built against) has exactly
  /// two cases — `.adjacency` and `.similar` — so "both pools unreachable" (design §4.2's Error
  /// state trigger) is simply "the degraded set contains both of them."
  static func isBothPoolsDown(_ degradedPools: Set<DeckPool>) -> Bool {
    degradedPools.contains(.adjacency) && degradedPools.contains(.similar)
  }
}
