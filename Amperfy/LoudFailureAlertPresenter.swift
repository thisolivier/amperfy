//
//  LoudFailureAlertPresenter.swift
//  Amperfy
//
//  Created for AMP-28 — failures the user must not be able to miss.
//  Copyright (c) 2026 Olivier Butler. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import OSLog
import UIKit

/// Puts a real modal alert in front of the user, wherever they currently are.
///
/// `EventLogger` banners are not loud. `AppDelegate.display(title:…)` bails out
/// on `topView.presentedViewController == nil` (AppDelegateAlertExtensions, the
/// `display(…)` guards), so a banner raised while ANY sheet is up — and the
/// "Add to Playlist" picker is a sheet — is dropped on the floor. That is
/// AMP-6, and it is why a rejected playlist add produced no user-visible
/// evidence at all.
///
/// This presenter instead walks the `presentedViewController` chain to its end
/// and presents there, so the alert lands on top of the sheet rather than
/// behind it. When there is no window to present into (backgrounded, no scene)
/// it falls back to the event log so the failure is still recorded.
@MainActor
enum LoudFailureAlertPresenter {
  private static let logger = Logger(subsystem: "Amperfy", category: "LoudFailureAlert")

  /// The deepest currently-presented view controller, or `nil` when there is no
  /// window.
  ///
  /// Deliberately NOT `AppDelegate.topViewController()`: that helper stops
  /// early at a tab bar / split controller and short-circuits when an alert is
  /// already up, both of which would hand back a controller that cannot
  /// present.
  static func deepestPresentedViewController() -> UIViewController? {
    guard var candidate = AppDelegate.window?.rootViewController else { return nil }
    while let presented = candidate.presentedViewController, !presented.isBeingDismissed {
      candidate = presented
    }
    return candidate
  }

  /// Present a single-action alert on the deepest presented controller.
  ///
  /// - Returns: `true` when an alert was actually presented.
  @discardableResult
  static func present(
    title: String,
    message: String,
    fallbackTopic: String,
    eventLogger: EventLogger
  )
    -> Bool {
    guard let presentingViewController = deepestPresentedViewController() else {
      logger.error("No window to present a loud failure alert on; falling back to the event log.")
      eventLogger.info(topic: fallbackTopic, message: message)
      return false
    }

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    presentingViewController.present(alert, animated: true)
    return true
  }

  /// The AMP-28 case: the server refused an add outright, so the songs are NOT
  /// in the playlist and the local copy has been rolled back.
  static func presentPlaylistAddRefusal(
    _ failure: PlaylistAddPermanentFailure,
    eventLogger: EventLogger
  ) {
    // Copy lives on the failure value itself (AmperfyKit) so it is unit-tested;
    // this layer only decides how loudly to show it.
    present(
      title: failure.userFacingTitle,
      message: failure.userFacingMessage,
      fallbackTopic: "Add Songs to Playlist",
      eventLogger: eventLogger
    )
  }
}
