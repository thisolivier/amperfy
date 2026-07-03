//
//  AuditionDeckHostVC.swift
//  Amperfy
//
//  Discovery-D4: UIKit presentation entry point for the Audition Deck
//  (docs/ux/amperfy-needle-drop-deck-v1-design.md §5.1). No SwiftUI-native
//  presentation (`.fullScreenCover`) precedent exists anywhere in this
//  predominantly-UIKit app, so this follows `SettingsHostVC.swift`'s
//  UIHostingController addChild/embed pattern, but configured as a genuinely
//  full-screen modal (`modalPresentationStyle = .fullScreen`) rather than
//  `SettingsHostVC`'s own-window setup.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - AuditionDeckHostVC

/// Call sites: `present(AuditionDeckHostVC(seed: .album(id: album.id), defaultKind: .album), animated: true)`
/// — this is the exact contract the entry-points agent's code needs; the `init` signature is kept
/// as specified and should not change without flagging it loudly to that agent.
class AuditionDeckHostVC: UIViewController {
  private let seed: DeckSeed
  private let defaultKind: DeckCandidateKind
  private var controller: AuditionDeckController?

  init(seed: DeckSeed, defaultKind: DeckCandidateKind) {
    self.seed = seed
    self.defaultKind = defaultKind
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    guard let account = resolveActiveAccount() else {
      // No active account to seed a deck from — mirrors the rest of this app's UIKit detail VCs,
      // which are likewise only ever constructed by a caller that already has a valid account in
      // hand (e.g. `AlbumDetailVC.init(account:album:)`). Entry points (design §2) are expected to
      // gate on this before presenting; nothing useful to show if it happens anyway.
      return
    }

    let deckController = makeDeckController(account: account)
    controller = deckController

    let deckView = AuditionDeckView(
      controller: deckController,
      account: account,
      onOpenCandidate: { [weak self] candidate in self?.openCandidate(candidate) },
      onRequestDismiss: { [weak self] in self?.requestDismiss() }
    )

    let hostingVC = UIHostingController(rootView: deckView)
    hostingVC.view.backgroundColor = .clear
    hostingVC.view.frame = view.bounds
    hostingVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    hostingVC.willMove(toParent: self)
    addChild(hostingVC)
    view.addSubview(hostingVC.view)
    hostingVC.didMove(toParent: self)

    Task {
      await deckController.deal(seed: seed, kind: defaultKind, blend: 0.5)
    }
  }

  /// VoiceOver's standard modal-dismiss gesture (two-finger Z) — design §7. `.fullScreen`
  /// presentation does not get this for free the way `.formSheet`/`.pageSheet` do, so it's
  /// implemented explicitly here, running the same close path as the in-deck X button.
  override func accessibilityPerformEscape() -> Bool {
    requestDismiss()
    return true
  }

  private func requestDismiss() {
    controller?.deckWillClose()
    dismiss(animated: true)
  }

  /// "Open" (design §5.2's more menu): dismiss the deck, then push the real detail screen onto
  /// whatever navigation stack presented it. Best-effort lookup of that navigation controller —
  /// worth a real-device check in the integration pass, since this app's navigation hierarchy at
  /// each of design §2's entry points wasn't something this file's author could exhaustively
  /// trace without also owning those entry-point call sites (another agent's files).
  private func openCandidate(_ candidate: DeckCandidate) {
    guard let account = resolveActiveAccount() else { return }
    let targetNavigationController = resolveTargetNavigationController()
    controller?.deckWillClose()
    dismiss(animated: true) {
      guard let entity = self.controller?.resolveEntity(candidate) else { return }
      switch candidate.kind {
      case .album:
        guard let album = entity as? Album else { return }
        targetNavigationController?.pushViewController(
          AlbumDetailVC(account: account, album: album), animated: true
        )
      case .playlist:
        guard let playlist = entity as? Playlist else { return }
        targetNavigationController?.pushViewController(
          PlaylistDetailVC(account: account, playlist: playlist), animated: true
        )
      }
    }
  }

  /// A full-screen modal's `presentingViewController` is the presentation
  /// context's root — on this app's main UI that is the tab bar controller,
  /// not the navigation controller the entry point lives in. The original
  /// direct cast therefore always resolved nil and "Open" silently dismissed
  /// without navigating (user-reported on build 57). Walk through the tab
  /// bar's selection to the real navigation stack.
  private func resolveTargetNavigationController() -> UINavigationController? {
    var candidate = presentingViewController
    if let tabBarController = candidate as? UITabBarController {
      candidate = tabBarController.selectedViewController
    }
    if let navigationController = candidate as? UINavigationController {
      return navigationController
    }
    return candidate?.navigationController
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
