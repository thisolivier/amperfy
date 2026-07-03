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

/// Blend chip / panel copy for the partial-degradation edge case (design §8): one pool
/// unreachable is NOT the Error state, it's a `Populated` deck with a degraded-pool banner.
enum AuditionDeckDegradedPoolMessage {
  static func text(for degradedPools: Set<DeckPool>) -> String? {
    let isAdjacencyDown = degradedPools.contains(.adjacency)
    let isSimilarDown = degradedPools.contains(.similar)
    switch (isAdjacencyDown, isSimilarDown) {
    case (true, false):
      return "Close matches unavailable right now"
    case (false, true):
      return "New directions unavailable"
    case (true, true):
      // Both pools down at once is the Error state (see `isBothPoolsDown` below) — this case
      // should not reach the banner, but a message is still returned defensively.
      return "Recommendations unavailable right now"
    case (false, false):
      return nil
    }
  }

  /// `DeckPool` (per the exact data-layer interface this sprint was built against) has exactly
  /// two cases — `.adjacency` and `.similar` — so "both pools unreachable" (design §4.2's Error
  /// state trigger) is simply "the degraded set contains both of them."
  static func isBothPoolsDown(_ degradedPools: Set<DeckPool>) -> Bool {
    degradedPools.contains(.adjacency) && degradedPools.contains(.similar)
  }
}
