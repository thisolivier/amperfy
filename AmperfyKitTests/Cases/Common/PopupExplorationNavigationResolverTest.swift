//
//  PopupExplorationNavigationResolverTest.swift
//  AmperfyKitTests
//
//  Locks in the fix/popup-navigation (build 74) invariant: onward-exploration
//  actions triggered from the popup/mini player ALWAYS collapse the player then
//  PUSH onto the currently-selected tab — never replace a tab root, never switch
//  to a hard-coded Library tab. The concrete UIKit routing (`TabBarVC` /
//  `SplitVC` / `PopupPlayerVC`) lives in the `Amperfy` app target, which
//  `AmperfyKitTests` cannot `@testable import` (same BUNDLE_LOADER limitation
//  documented in DeckDealingGateTest), so the decision was extracted to the pure
//  `PopupExplorationNavigationResolver` in AmperfyKit and is asserted here.
//

@testable import AmperfyKit
import XCTest

// MARK: - PopupExplorationNavigationResolverTest

final class PopupExplorationNavigationResolverTest: XCTestCase {
  // MARK: Popup-player origin — the bug's origin

  /// The reported symptom: from the popup player, the destination must land on
  /// the current tab, after collapsing the player — in that order.
  func testPopupPlayerOriginCollapsesThenPushesOntoCurrentTab() {
    let steps = PopupExplorationNavigationResolver.steps(for: .popupPlayer)
    XCTAssertEqual(steps, [.collapsePopupPlayer, .pushOntoCurrentTab])
  }

  /// Regression guard: the popup route must NEVER push onto a hard-coded tab or
  /// replace a root — that was exactly the bricking behaviour.
  func testPopupPlayerOriginNeverTargetsLibraryTabAndNeverReplacesRoot() {
    XCTAssertFalse(
      PopupExplorationNavigationResolver.targetsHardCodedLibraryTab(for: .popupPlayer),
      "Popup exploration must target the CURRENT tab, not a hard-coded Library tab"
    )
    XCTAssertFalse(
      PopupExplorationNavigationResolver.replacesRoot(for: .popupPlayer),
      "Popup exploration must PUSH, never replace a tab root"
    )
    let steps = PopupExplorationNavigationResolver.steps(for: .popupPlayer)
    XCTAssertFalse(steps.contains(.pushOntoCurrentTabViaHost))
    XCTAssertFalse(steps.contains(.pushOntoOriginNavigationController))
  }

  // MARK: Screen-with-nav origin

  func testScreenWithNavigationControllerPushesOntoOwnStack() {
    let steps = PopupExplorationNavigationResolver
      .steps(for: .screenWithNavigationController)
    XCTAssertEqual(steps, [.pushOntoOriginNavigationController])
  }

  // MARK: Detached origin

  func testDetachedOriginPushesOntoCurrentTabViaHost() {
    let steps = PopupExplorationNavigationResolver.steps(for: .detached)
    XCTAssertEqual(steps, [.pushOntoCurrentTabViaHost])
  }

  // MARK: Global invariants across every origin

  /// No origin may ever produce a replace-root or hard-coded-Library-tab route.
  /// This is the single assertion that catches a future regression reintroducing
  /// the `pushNavLibrary`-from-popup behaviour.
  func testNoOriginEverReplacesRootOrTargetsLibraryTab() {
    let allOrigins: [PopupExplorationOrigin] = [
      .popupPlayer, .screenWithNavigationController, .detached,
    ]
    for origin in allOrigins {
      XCTAssertFalse(
        PopupExplorationNavigationResolver.replacesRoot(for: origin),
        "\(origin) must never replace a navigation root"
      )
      XCTAssertFalse(
        PopupExplorationNavigationResolver.targetsHardCodedLibraryTab(for: origin),
        "\(origin) must never target a hard-coded Library tab"
      )
    }
  }

  /// Every route must contain exactly one push step (the destination lands once),
  /// and popup routes must collapse the player before that push.
  func testEveryRouteHasExactlyOnePushAndPopupCollapsesFirst() {
    let allOrigins: [PopupExplorationOrigin] = [
      .popupPlayer, .screenWithNavigationController, .detached,
    ]
    let pushSteps: Set<PopupExplorationNavStep> = [
      .pushOntoCurrentTab, .pushOntoOriginNavigationController, .pushOntoCurrentTabViaHost,
    ]
    for origin in allOrigins {
      let steps = PopupExplorationNavigationResolver.steps(for: origin)
      XCTAssertEqual(
        steps.filter { pushSteps.contains($0) }.count, 1,
        "\(origin) must push the destination exactly once"
      )
      if let collapseIndex = steps.firstIndex(of: .collapsePopupPlayer),
         let pushIndex = steps.firstIndex(where: { pushSteps.contains($0) }) {
        XCTAssertLessThan(
          collapseIndex, pushIndex,
          "The popup must collapse BEFORE the push so the destination is visible"
        )
      }
    }
  }
}
