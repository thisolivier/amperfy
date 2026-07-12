//
//  GigsAddCityPrompt.swift
//  Amperfy
//
//  Shared "Add City" prompt for the Gigs feature. Both the Gigs list (GigsVC)
//  and the manage-cities screen (GigsCitiesVC) present an identical add-city
//  alert; this helper is the single source of that prompt + copy, and folds in
//  the "Already following <city>" feedback (A4) by surfacing GigsSettings.addCity's
//  Bool result to the caller.
//
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
import UIKit

// MARK: - GigsAddCityPrompt

@MainActor
enum GigsAddCityPrompt {
  /// What happened when the user confirmed the add-city prompt.
  enum Outcome {
    /// A new city was added; callers should re-fetch.
    case added
    /// The entered city (as typed) is already followed; callers show feedback.
    case alreadyFollowing(String)
    /// Blank / whitespace-only input; callers do nothing.
    case blank
  }

  /// Present the shared "Add City" alert from `presenter`, persist via
  /// `settings`, and report the outcome. `Cancel` never calls `completion`.
  static func present(
    from presenter: UIViewController,
    settings: GigsSettings,
    completion: @escaping (Outcome) -> ()
  ) {
    let alert = UIAlertController(
      title: "Add City",
      message: "Show upcoming gigs in this city.",
      preferredStyle: .alert
    )
    alert.addTextField { $0.placeholder = "e.g. London" }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
      let entered = (alert.textFields?.first?.text ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !entered.isEmpty else {
        completion(.blank)
        return
      }
      if settings.addCity(entered) {
        completion(.added)
      } else {
        completion(.alreadyFollowing(entered))
      }
    })
    presenter.present(alert, animated: true)
  }
}
