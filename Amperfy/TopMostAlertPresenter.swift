//
//  TopMostAlertPresenter.swift
//  Amperfy
//
//  Created by Olivier Butler on 23.10.26.
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
import os.log
import UIKit

/// Presents a modal alert on top of whatever is currently on screen, for the
/// few failures the user must not be able to miss.
///
/// Notification banners are not an option for these. `AppDelegate`'s
/// `display(title:subtitle:style:notificationBanner:)` requires
/// `topView.presentedViewController == nil`, so a banner raised while any sheet
/// is up is silently discarded — and the playlist add flows run their upload
/// from a presented sheet, which is exactly when their failures need saying.
///
/// `AppDelegate.topViewController()` cannot be used to present either: it stops
/// at the tab bar / split controller and short-circuits when an alert is
/// already up, both of which hand back a controller that is not allowed to
/// present. This walks the `presentedViewController` chain to its end instead,
/// skipping controllers on their way out, so the alert lands on top of the
/// sheet rather than behind it.
@MainActor
enum TopMostAlertPresenter {
  private static let log = OSLog(subsystem: "Amperfy", category: "TopMostAlertPresenter")

  /// How long to keep waiting for an in-flight dismissal before giving up and
  /// recording the message in the event log instead.
  private static let transitionRetryDelay = Duration.milliseconds(250)
  private static let transitionRetryLimit = 12

  /// The deepest currently presented view controller, or `nil` when there is no
  /// window to present into.
  static func topMostViewController() -> UIViewController? {
    guard var candidate = AppDelegate.window?.rootViewController else { return nil }
    while let presented = candidate.presentedViewController, !presented.isBeingDismissed {
      candidate = presented
    }
    return candidate
  }

  /// Present a single-action alert on the top-most view controller.
  ///
  /// Falls back to the event log when the app has no window (backgrounded, no
  /// scene) so the message is still recorded somewhere.
  static func display(
    title: String,
    message: String,
    fallbackTopic: String,
    eventLogger: EventLogger
  ) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(
      alert,
      fallbackMessage: message,
      fallbackTopic: fallbackTopic,
      eventLogger: eventLogger,
      remainingAttempts: transitionRetryLimit
    )
  }

  /// These alerts are raised from the very flows that are closing their own
  /// sheet, so a dismissal is usually still animating. UIKit refuses a
  /// presentation on a controller that is mid-transition, so wait the
  /// transition out rather than losing the alert to it — losing it is the bug
  /// this presenter exists to fix.
  private static func present(
    _ alert: UIAlertController,
    fallbackMessage: String,
    fallbackTopic: String,
    eventLogger: EventLogger,
    remainingAttempts: Int
  ) {
    guard let presentingVC = topMostViewController() else {
      os_log(
        "No window to present an alert on; falling back to the event log",
        log: log,
        type: .error
      )
      eventLogger.info(topic: fallbackTopic, message: fallbackMessage)
      return
    }

    // The walk above only stops on a controller whose presentation is being
    // dismissed, so a non-nil value here means a transition is in flight.
    guard presentingVC.presentedViewController == nil else {
      guard remainingAttempts > 0 else {
        os_log(
          "A view controller transition never settled; falling back to the event log",
          log: log,
          type: .error
        )
        eventLogger.info(topic: fallbackTopic, message: fallbackMessage)
        return
      }
      Task { @MainActor in
        try? await Task.sleep(for: transitionRetryDelay)
        present(
          alert,
          fallbackMessage: fallbackMessage,
          fallbackTopic: fallbackTopic,
          eventLogger: eventLogger,
          remainingAttempts: remainingAttempts - 1
        )
      }
      return
    }

    presentingVC.present(alert, animated: true)
  }

  /// The server refused a playlist add outright, so the songs are not in the
  /// playlist. The wording lives on ``PlaylistAddRejection`` in AmperfyKit;
  /// this layer only decides how loudly to show it.
  static func display(rejection: PlaylistAddRejection, eventLogger: EventLogger) {
    display(
      title: rejection.userFacingTitle,
      message: rejection.userFacingMessage,
      fallbackTopic: "Add Songs to Playlist",
      eventLogger: eventLogger
    )
  }
}
