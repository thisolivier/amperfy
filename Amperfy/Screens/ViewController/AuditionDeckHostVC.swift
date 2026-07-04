//
//  AuditionDeckHostVC.swift
//  Amperfy
//
//  Deck v2 (docs/ux/amperfy-discovery-v3-backlog.md "Deck v2 redesign"): the
//  Audition Deck is a PUSHED page on the presenting navigation stack, not a
//  modal. Tapping a card pushes that collection's detail onto the same stack
//  while the deck stays alive beneath it — popping back returns to the live
//  deck with no re-deal. The system back button replaces the old X/Close.
//  SwiftUI content is embedded via the UIHostingController addChild/embed
//  pattern (`SettingsHostVC.swift` precedent).
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - AuditionDeckHostVC

/// Call sites use `pushAuditionDeck(seed:defaultKind:)` (bottom of this file) rather than
/// constructing this VC directly — it carries the ec5fff6 routing fallbacks (popup player,
/// missing navigation controller).
class AuditionDeckHostVC: UIViewController {
  private let seed: DeckSeed
  private let defaultKind: DeckCandidateKind
  private var controller: AuditionDeckController?
  private var themeBackgroundView: GradientBackgroundView?
  private var hostingVC: UIHostingController<AuditionDeckView>?

  init(seed: DeckSeed, defaultKind: DeckCandidateKind) {
    self.seed = seed
    self.defaultKind = defaultKind
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    installThemeBackground()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleThemeDidChange),
      name: ThemeStore.didChangeNotification,
      object: nil
    )

    guard let account = resolveActiveAccount() else {
      // No active account to seed a deck from — mirrors the rest of this app's UIKit detail VCs,
      // which are likewise only ever constructed by a caller that already has a valid account in
      // hand (e.g. `AlbumDetailVC.init(account:album:)`). Entry points (design §2) are expected to
      // gate on this before pushing; nothing useful to show if it happens anyway.
      return
    }

    let deckController = makeDeckController(account: account)
    controller = deckController

    let hostingController = UIHostingController(rootView: makeDeckView(
      controller: deckController,
      account: account
    ))
    hostingController.view.backgroundColor = .clear
    hostingController.view.frame = view.bounds
    hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    hostingController.willMove(toParent: self)
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)
    hostingVC = hostingController

    Task {
      await deckController.deal(seed: seed, kind: defaultKind)
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  /// Deck v2 audio semantics: sprite audio must never keep playing once this page is not the
  /// visible one. Leaving via POP (back button, end-card Done) is "deck closed" — run the full
  /// close handoff (stop sprites + resume the main player if it was playing on entry and no
  /// handoff happened). Leaving because a detail was PUSHED on top (card tap) only silences
  /// sprite audio; the deck session stays alive for the pop back.
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isMovingFromParent {
      controller?.deckWillClose()
    } else {
      controller?.audio.stopAllSpritePlayers()
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      installThemeBackground()
      refreshDeckViewChrome()
    }
  }

  @objc
  private func handleThemeDidChange() {
    installThemeBackground()
    refreshDeckViewChrome()
  }

  // MARK: Theming (Deck v2 page look)

  /// Full theme surface behind the SwiftUI deck, exactly as Home does it: the user's gradient
  /// when one is active, else the solid custom background, else the system background. Same
  /// behind-the-host-VC injection as `SettingsHostVC.installThemeBackground()` — the deck's
  /// SwiftUI root is transparent so cards render on this surface.
  private func installThemeBackground() {
    themeBackgroundView?.removeFromSuperview()
    themeBackgroundView = nil
    let style = traitCollection.userInterfaceStyle
    if let gradient = ThemeStore.shared.resolvedGradient(for: style) {
      let backdrop = GradientBackgroundView(gradient: gradient)
      backdrop.frame = view.bounds
      backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.insertSubview(backdrop, at: 0)
      themeBackgroundView = backdrop
      view.backgroundColor = .clear
    } else if let solid = ThemeStore.shared.dynamicBackground {
      view.backgroundColor = solid
    } else {
      view.backgroundColor = .systemBackground
    }
  }

  /// Re-derives the accent-dependent SwiftUI chrome (page title color) after a theme change.
  private func refreshDeckViewChrome() {
    guard let controller, let account = resolveActiveAccount() else { return }
    hostingVC?.rootView = makeDeckView(controller: controller, account: account)
  }

  private func makeDeckView(
    controller: AuditionDeckController,
    account: Account
  )
    -> AuditionDeckView {
    AuditionDeckView(
      controller: controller,
      account: account,
      pageTitle: pageTitle(account: account),
      accentColor: resolvedAccentColor(),
      onOpenCandidate: { [weak self] candidate in self?.openCandidate(candidate) },
      onRequestDismiss: { [weak self] in self?.popDeck() }
    )
  }

  /// "Recommended Playlists from <SEED NAME>" / "Recommended Albums from <SEED NAME>" (Deck v2
  /// brief). History seeds read as "…from your recent listening" via `DeckSeedResolver`'s same
  /// phrasing.
  private func pageTitle(account: Account) -> String {
    let kindWord = defaultKind == .playlist ? "Playlists" : "Albums"
    return "Recommended \(kindWord) from \(seedDisplayName(account: account))"
  }

  private func seedDisplayName(account: Account) -> String {
    let library = appDelegate.storage.main.library
    switch seed {
    case let .playlist(id):
      return library.getPlaylist(for: account, id: id)?.name ?? "this playlist"
    case let .album(id):
      return library.getAlbum(for: account, id: id, isDetailFaultResolution: false)?
        .name ?? "this album"
    case .recentHistory:
      return "your recent listening"
    }
  }

  /// Account-theme accent for the page title — the same source the app's theming uses
  /// (`ThemeStore.tintColor(for:)`, the store behind `view.tintColor` when the custom theme is
  /// on; `RelatedTracksVC`'s header pattern). Dynamic provider so light/dark resolve per render;
  /// falls back to the view's inherited tint when no custom theme is enabled.
  private func resolvedAccentColor() -> Color {
    Color(uiColor: UIColor { traits in
      ThemeStore.shared.tintColor(for: traits.userInterfaceStyle) ?? .tintColor
    })
  }

  // MARK: Navigation

  private func popDeck() {
    navigationController?.popViewController(animated: true)
  }

  /// Whole-card tap (Deck v2): push the collection's detail onto the SAME stack — the deck stays
  /// alive beneath and popping returns to it live (replaces v1's dismiss-then-push "Open").
  private func openCandidate(_ candidate: DeckCandidate) {
    guard let account = resolveActiveAccount() else { return }
    guard let entity = controller?.resolveEntity(candidate) else { return }
    let detailVC: UIViewController
    switch candidate.kind {
    case .album:
      guard let album = entity as? Album else { return }
      detailVC = AlbumDetailVC(account: account, album: album)
    case .playlist:
      guard let playlist = entity as? Playlist else { return }
      detailVC = PlaylistDetailVC(account: account, playlist: playlist)
    }
    navigationController?.pushViewController(detailVC, animated: true)
  }

  private func resolveActiveAccount() -> Account? {
    guard let activeAccountInfo = appDelegate.storage.settings.accounts.active else { return nil }
    return appDelegate.storage.main.library.getAccount(info: activeAccountInfo)
  }

  private func makeDeckController(account: Account) -> AuditionDeckController {
    let storage = appDelegate.storage.main.library
    let fusionEngine = DeckFusionEngine(
      familiarPool: AdjacencySidecarClient(serverUrl: account.serverUrl),
      adventurousPool: OnDeviceAdventurousPoolProvider(storage: storage, account: account),
      storage: storage
    )
    let likeCoordinator = AuditionDeckLikeCoordinator(storage: storage, account: account)
    return AuditionDeckController(
      account: account,
      fusionEngine: fusionEngine,
      storage: storage,
      player: appDelegate.player,
      likeCoordinator: likeCoordinator
    )
  }
}

// MARK: - Entry-point routing

extension UIViewController {
  /// Push the Audition Deck onto the current navigation stack, with the same routing fallbacks
  /// the user-settled push-navigation rule established in ec5fff6 (Related Tracks): popup player
  /// closes into the library tab first; a caller with no navigation controller routes through the
  /// main window host.
  func pushAuditionDeck(seed: DeckSeed, defaultKind: DeckCandidateKind) {
    let deckVC = AuditionDeckHostVC(seed: seed, defaultKind: defaultKind)
    if let popupPlayer = self as? PopupPlayerVC {
      popupPlayer.closePopupPlayerAndDisplayInLibraryTab(vc: deckVC)
    } else if let navController = navigationController {
      navController.pushViewController(deckVC, animated: true)
    } else if let hostingSplitVC = AppDelegate.mainWindowHostVC {
      hostingSplitVC.pushNavLibrary(vc: deckVC)
    }
  }
}
