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
/// deck opens and discarded on dismiss — `excludeIds` and the session counters therefore live
/// exactly as long as design §8's "session de-dupe... never reset until the deck is dismissed"
/// requires, with no separate reset step needed.
///
/// `blend` is a plain `@Published` property on purpose: the blend panel
/// (`AuditionDeckBlendPanel.swift`, found already built) binds `$controller.blend` directly as its
/// `Slider`'s two-way binding and calls `refresh()` itself once its own 400ms debounce settles —
/// this controller does not auto-react to `blend` changing. Deck length is intentionally NOT
/// mirrored as a controller property: `AuditionDeckBlendPanel` owns it via
/// `@AppStorage("amperfy.fork.discovery.deckLength")`, so `dealMore()` reads that same
/// `UserDefaults` key directly (`Self.deckLengthDefaultsKey`) rather than risking two
/// independently-tracked copies drifting apart. This is a fragile string-literal coupling across
/// two concurrently-written files — flagged in this sprint's report for the integration pass to
/// double check against `AuditionDeckBlendPanel.swift`'s actual key if it changes.
@MainActor
final class AuditionDeckController: ObservableObject {
  /// Must match `AuditionDeckBlendPanel.swift`'s `@AppStorage` key exactly — see the type doc.
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
  @Published
  var blend: Double

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

  var sessionAuditionedCount: Int { auditionedCandidateIds.count }

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
  var auditionedCandidateIds: Set<String> = []
  /// Snapshot of like state taken the moment each candidate was first dealt (initial deal or Deal
  /// More) — the baseline `sessionLikedCount` diffs against.
  var likedBeforeSessionIds: Set<String> = []

  var deckLength: Int {
    let stored = UserDefaults.standard.object(forKey: Self.deckLengthDefaultsKey) as? Int
    return stored ?? Self.defaultDeckLength
  }

  init(
    account: Account,
    fusionEngine: DeckFusionEngine,
    storage: LibraryStorage,
    player: PlayerFacade,
    likeCoordinator: AuditionDeckLikeCoordinator,
    initialBlend: Double = 0.5
  ) {
    self.account = account
    self.fusionEngine = fusionEngine
    self.storage = storage
    self.player = player
    self.likeCoordinator = likeCoordinator
    self.audio = AuditionDeckAudioCoordinator(player: player)
    self.blend = initialBlend
    audio.onFirstAudition = { [weak self] candidateId in
      self?.auditionedCandidateIds.insert(candidateId)
    }
  }

  // MARK: Entity resolution / playback

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

  /// Hands off to the main player queue starting at `startTrackId` (or track 1 if nil), stops
  /// sprite audio, and marks the audio handoff so `deckWillClose()` doesn't also resume whatever
  /// was playing before the deck opened. Returns `false` if the entity couldn't be resolved.
  @discardableResult
  func play(candidate: DeckCandidate, startTrackId: String?) -> Bool {
    guard let containable = resolveEntity(candidate) else { return false }
    let playables = containable.playables
    let index = startTrackId.flatMap { trackId in
      playables.firstIndex(where: { $0.id == trackId })
    } ?? 0
    audio.stopAllSpritePlayers()
    audio.markPlayHandedOffToMainPlayer()
    player.play(context: PlayContext(containable: containable, index: index, playables: playables))
    return true
  }

  func playShuffled(candidate: DeckCandidate) {
    guard let containable = resolveEntity(candidate) else { return }
    audio.stopAllSpritePlayers()
    audio.markPlayHandedOffToMainPlayer()
    player.playShuffled(context: PlayContext(
      containable: containable,
      playables: containable.playables
    ))
  }

  func addToQueue(candidate: DeckCandidate) {
    guard let containable = resolveEntity(candidate) else { return }
    player.appendContextQueue(playables: containable.playables)
  }

  func deckWillClose() {
    audio.deckWillClose()
  }
}
