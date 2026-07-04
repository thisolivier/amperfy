import AmperfyKit
import Foundation

// MARK: - AuditionDeckController

/// Owns all deck-wide state for one Audition Deck session (design §3.1/§4.2): the dealt
/// candidates, lifecycle state, session de-dupe, and session counters. Audio handoff / the
/// single-active-sprite-player invariant live in `AuditionDeckAudioCoordinator`; like *reads* (for
/// the refresh-pinning rule and the session-liked counter — the like *button* itself is
/// `AuditionDeckLikeButton.swift`, another agent's file, used directly by the card view) live in
/// `AuditionDeckLikeCoordinator`.
///
/// Not `public` — like every other type under `Amperfy/Screens/Discovery/`, this is app-target
/// code, not a framework boundary, so `internal` (the default) is enough for every other file in
/// this target to use it.
///
/// One instance == one deck session. It is created fresh by `AuditionDeckHostVC` each time the
/// deck opens and discarded when the page pops — `excludeIds` and the session counters therefore
/// live exactly as long as design §8's "session de-dupe... never reset until the deck is
/// dismissed" requires, with no separate reset step needed.
///
/// Deck v2: the blend UI (chip/panel/slider) is gone. The blend *machinery* is retained —
/// `DeckFusionEngine.deal(blend:)` is unchanged — but this controller now drives it internally:
/// sidecar-first (blend 0.0) with a silent on-device fallback (blend 1.0) when the familiar pool
/// is degraded (see `AuditionDeckController+Dealing.swift`).
@MainActor
final class AuditionDeckController: ObservableObject {
  /// Historic `@AppStorage` key of the removed blend panel's deck-length picker — still honored
  /// so an existing install's chosen deck length survives the Deck v2 UI removal.
  static let deckLengthDefaultsKey = "amperfy.fork.discovery.deckLength"
  static let defaultDeckLength = 10

  @Published
  var lifecycleState: AuditionDeckLifecycleState = .dealing
  @Published
  var isRefreshing = false
  @Published
  var isExtending = false
  @Published
  var refreshBannerVisible = false
  @Published
  var candidates: [DeckCandidate] = []
  @Published
  var scrollPositionId: String?
  @Published
  var degradedPools: Set<DeckPool> = []

  let audio: AuditionDeckAudioCoordinator

  var uiState: AuditionDeckUIState {
    switch lifecycleState {
    case .dealing: return .dealing
    case .empty: return .empty
    case let .error(message): return .error(message: message)
    case .populated:
      if isRefreshing { return .refreshing }
      if isExtending { return .extended }
      return .populated
    }
  }

  /// "Likes made this session" (design §5.5): candidates currently liked that were NOT already
  /// liked at the moment they were dealt into this session. Computed live against
  /// `likeCoordinator.isLiked` rather than accumulated from button taps, since
  /// `AuditionDeckLikeButton` (another agent's self-contained view) has no callback to push
  /// toggle events back to this controller.
  var sessionLikedCount: Int {
    candidates.filter { candidate in
      likeCoordinator.isLiked(candidate) && !likedBeforeSessionIds.contains(candidate.collectionId)
    }.count
  }

  // Not `private`: `AuditionDeckController+Dealing.swift` (an extension of this same type, in a
  // different file, still within this target — Swift's `private`/`fileprivate` access control is
  // file-scoped, not type-scoped) needs to read/write these too.
  let fusionEngine: DeckFusionEngine
  let storage: LibraryStorage
  let player: PlayerFacade
  let account: Account
  let likeCoordinator: AuditionDeckLikeCoordinator

  var currentSeed: DeckSeed?
  var currentKind: DeckCandidateKind?
  var excludeIds: Set<String> = []
  /// Snapshot of like state taken the moment each candidate was first dealt (initial deal or Deal
  /// More) — the baseline `sessionLikedCount` diffs against.
  var likedBeforeSessionIds: Set<String> = []

  /// Single shared gate `refresh()` and `dealMore()` both run through — neither is safe to run
  /// concurrently with the other, or with a second call to itself, since both mutate
  /// `candidates`/`excludeIds`/`likedBeforeSessionIds` and `refresh()` snapshots `candidates`
  /// before its own `await` — an unguarded overlap is exactly the re-entrancy bug this gate
  /// closes (D4 Director review finding). Extracted to `AmperfyKit.DeckDealingGate` so the
  /// mutual-exclusion mechanism itself is unit-testable without needing `Amperfy`-app-target
  /// testability (see that type's doc comment for why). Not `private`, same reasoning as
  /// `excludeIds` et al. above: `AuditionDeckController+Dealing.swift` needs to read this too.
  let dealingGate = DeckDealingGate()

  var deckLength: Int {
    let stored = UserDefaults.standard.object(forKey: Self.deckLengthDefaultsKey) as? Int
    return stored ?? Self.defaultDeckLength
  }

  init(
    account: Account,
    fusionEngine: DeckFusionEngine,
    storage: LibraryStorage,
    player: PlayerFacade,
    likeCoordinator: AuditionDeckLikeCoordinator
  ) {
    self.account = account
    self.fusionEngine = fusionEngine
    self.storage = storage
    self.player = player
    self.likeCoordinator = likeCoordinator
    self.audio = AuditionDeckAudioCoordinator(player: player)
  }

  // MARK: Entity resolution

  /// Deck v2 removed all in-deck playback (Play/Shuffle/queue) — playing happens after opening
  /// the collection, so this controller's only entity work is resolving a candidate for the
  /// card's artwork and the host's detail push.
  func resolveEntity(_ candidate: DeckCandidate) -> PlayableContainable? {
    switch candidate.kind {
    case .album:
      return storage.getAlbum(
        for: account,
        id: candidate.collectionId,
        isDetailFaultResolution: true
      )
    case .playlist:
      return storage.getPlaylist(for: account, id: candidate.collectionId)
    }
  }

  /// Deck v2: fired when the deck page POPS off the navigation stack (not on modal dismissal —
  /// there is no modal anymore). `AuditionDeckHostVC.viewWillDisappear(isMovingFromParent:)`
  /// is the caller.
  func deckWillClose() {
    audio.deckWillClose()
  }
}
