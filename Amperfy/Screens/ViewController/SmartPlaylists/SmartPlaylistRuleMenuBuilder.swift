//
//  SmartPlaylistRuleMenuBuilder.swift
//  Amperfy
//
//  UIMenu construction for the smart playlist rule builder (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistRuleMenuBuilder

/// Builds the menus the rule builder puts behind its rows.
///
/// Every value a rule can hold is a small integer, so tapping a row opens a
/// menu of sensible presets rather than a keyboard — that keeps the common
/// cases one tap away. "Custom…" is the escape hatch for the day-count rules,
/// handed back to the view controller because it needs an alert with a text
/// field. Playlist-membership rules have no menu at all: their value is a
/// playlist, chosen in `SmartPlaylistPlaylistPickerVC`.
@MainActor
enum SmartPlaylistRuleMenuBuilder {
  /// Windows offered for "added in the last N days" and the play-history day
  /// rules. Weekly → yearly, matching how people actually describe a backlog.
  static let dayPresets = [7, 14, 30, 60, 90, 180, 365]
  /// Thresholds offered for the playlist-count rule.
  static let playlistCountPresets = [1, 2, 3, 5, 10]

  /// The "+ Add rule" menu for one container.
  ///
  /// Repeatability is decided per container — the top level and every group
  /// each get their own single instance of the non-repeatable kinds — so the
  /// caller passes the kinds it has already filtered through
  /// `SmartPlaylistQuery.addableRuleKinds(forGroupAt:)`. Returns `nil` when
  /// nothing is left to add, which the calling row renders as a disabled
  /// affordance.
  static func makeAddRuleMenu(
    title: String,
    addableKinds: [SmartPlaylistRule.Kind],
    onAddRuleOfKind: @escaping (SmartPlaylistRule.Kind) -> ()
  )
    -> UIMenu? {
    guard !addableKinds.isEmpty else { return nil }
    let actions = addableKinds.map { ruleKind in
      UIAction(title: ruleKind.displayName) { _ in onAddRuleOfKind(ruleKind) }
    }
    return UIMenu(title: title, children: actions)
  }

  /// The "+ Add group" menu.
  ///
  /// A new group is empty, and an empty group says nothing — so rather than
  /// dropping an empty card on screen and cleaning it up afterwards, the button
  /// asks for the group's FIRST RULE straight away and creates the group around
  /// the answer. Dismissing the menu therefore leaves nothing behind. An empty
  /// container accepts every rule kind, so no filtering applies here.
  static func makeAddGroupMenu(
    onAddFirstRuleOfKind: @escaping (SmartPlaylistRule.Kind) -> ()
  )
    -> UIMenu {
    let actions = SmartPlaylistRule.Kind.allCases.map { ruleKind in
      UIAction(title: ruleKind.displayName) { _ in onAddFirstRuleOfKind(ruleKind) }
    }
    return UIMenu(title: "New Group — First Rule", children: actions)
  }

  /// The group card's ⋯ menu: the combinator (reachable even for a one-rule
  /// group, which shows no chips) and the destructive removal.
  static func makeGroupOptionsMenu(
    combinator: SmartPlaylistCombinator,
    onCombinatorChosen: @escaping (SmartPlaylistCombinator) -> (),
    onDeleteGroupRequested: @escaping () -> ()
  )
    -> UIMenu {
    let combinatorActions = SmartPlaylistCombinator.allCases.map { candidate in
      UIAction(
        title: candidate == .all ? "Match all of these" : "Match any of these",
        state: candidate == combinator ? .on : .off
      ) { _ in
        onCombinatorChosen(candidate)
      }
    }
    let combinatorMenu = UIMenu(title: "", options: .displayInline, children: combinatorActions)
    let deleteAction = UIAction(
      title: "Delete Group",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { _ in
      onDeleteGroupRequested()
    }
    let deleteMenu = UIMenu(title: "", options: .displayInline, children: [deleteAction])
    return UIMenu(title: "Group", children: [combinatorMenu, deleteMenu])
  }

  /// The edit menu for a value-carrying rule, or `nil` for the playlist rules
  /// whose editing flow is a pushed picker instead.
  static func makeEditMenu(
    for rule: SmartPlaylistRule,
    onRuleEdited: @escaping (SmartPlaylistRule) -> (),
    onCustomDayCountRequested: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu? {
    switch rule {
    case let .addedWithinDays(currentDays):
      return makeAddedWithinDaysMenu(
        currentDays: currentDays,
        onRuleEdited: onRuleEdited,
        onCustomDayCountRequested: onCustomDayCountRequested
      )
    case let .played(currentPlayedRule):
      return makePlayedMenu(
        currentPlayedRule: currentPlayedRule,
        onRuleEdited: onRuleEdited,
        onCustomDayCountRequested: onCustomDayCountRequested
      )
    case let .playlistCount(currentComparison, currentCount):
      return makePlaylistCountMenu(
        currentComparison: currentComparison,
        currentCount: currentCount,
        onRuleEdited: onRuleEdited
      )
    case let .completeAlbum(isComplete):
      return makeCompleteAlbumMenu(isComplete: isComplete, onRuleEdited: onRuleEdited)
    case .inPlaylist, .notInPlaylist:
      return nil
    }
  }

  // MARK: - Complete album

  private static func makeCompleteAlbumMenu(
    isComplete: Bool,
    onRuleEdited: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu {
    let actions = [true, false].map { isCompleteChoice in
      UIAction(
        title: SmartPlaylistRule.completeAlbum(isComplete: isCompleteChoice).displayText,
        state: isCompleteChoice == isComplete ? .on : .off
      ) { _ in
        onRuleEdited(.completeAlbum(isComplete: isCompleteChoice))
      }
    }
    return UIMenu(title: "Complete album", children: actions)
  }

  // MARK: - Added-within-days

  private static func makeAddedWithinDaysMenu(
    currentDays: Int,
    onRuleEdited: @escaping (SmartPlaylistRule) -> (),
    onCustomDayCountRequested: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu {
    var actions = dayPresets.map { presetDays in
      UIAction(
        title: dayCountTitle(presetDays),
        state: presetDays == currentDays ? .on : .off
      ) { _ in
        onRuleEdited(.addedWithinDays(presetDays))
      }
    }
    actions.append(UIAction(title: "Custom\u{2026}") { _ in
      onCustomDayCountRequested(.addedWithinDays(currentDays))
    })
    return UIMenu(title: "Added in the last\u{2026}", children: actions)
  }

  // MARK: - Play history

  private static func makePlayedMenu(
    currentPlayedRule: SmartPlaylistPlayedRule,
    onRuleEdited: @escaping (SmartPlaylistRule) -> (),
    onCustomDayCountRequested: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu {
    let neverPlayedAction = UIAction(
      title: "Never played",
      state: currentPlayedRule == .never ? .on : .off
    ) { _ in
      onRuleEdited(.played(.never))
    }

    var currentNotInLastDays: Int?
    var currentInLastDays: Int?
    switch currentPlayedRule {
    case .never: break
    case let .notInLastDays(days): currentNotInLastDays = days
    case let .inLastDays(days): currentInLastDays = days
    }

    let notPlayedMenu = makeDayPresetSubmenu(
      title: "Not played in the last\u{2026}",
      selectedDays: currentNotInLastDays,
      makeRule: { .played(.notInLastDays($0)) },
      customFallbackRule: .played(.notInLastDays(currentNotInLastDays ?? 30)),
      onRuleEdited: onRuleEdited,
      onCustomDayCountRequested: onCustomDayCountRequested
    )
    let playedMenu = makeDayPresetSubmenu(
      title: "Played in the last\u{2026}",
      selectedDays: currentInLastDays,
      makeRule: { .played(.inLastDays($0)) },
      customFallbackRule: .played(.inLastDays(currentInLastDays ?? 30)),
      onRuleEdited: onRuleEdited,
      onCustomDayCountRequested: onCustomDayCountRequested
    )
    return UIMenu(
      title: "Play History",
      children: [neverPlayedAction, notPlayedMenu, playedMenu]
    )
  }

  private static func makeDayPresetSubmenu(
    title: String,
    selectedDays: Int?,
    makeRule: @escaping (Int) -> SmartPlaylistRule,
    customFallbackRule: SmartPlaylistRule,
    onRuleEdited: @escaping (SmartPlaylistRule) -> (),
    onCustomDayCountRequested: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu {
    var actions = dayPresets.map { presetDays in
      UIAction(
        title: dayCountTitle(presetDays),
        state: presetDays == selectedDays ? .on : .off
      ) { _ in
        onRuleEdited(makeRule(presetDays))
      }
    }
    actions.append(UIAction(title: "Custom\u{2026}") { _ in
      onCustomDayCountRequested(customFallbackRule)
    })
    return UIMenu(title: title, children: actions)
  }

  // MARK: - Playlist count

  private static func makePlaylistCountMenu(
    currentComparison: SmartPlaylistCountComparison,
    currentCount: Int,
    onRuleEdited: @escaping (SmartPlaylistRule) -> ()
  )
    -> UIMenu {
    let comparisonMenus = SmartPlaylistCountComparison.allCases.map { comparison in
      let actions = playlistCountPresets.map { presetCount in
        UIAction(
          title: presetCount == 1 ? "1 playlist" : "\(presetCount) playlists",
          state: (comparison == currentComparison && presetCount == currentCount) ? .on : .off
        ) { _ in
          onRuleEdited(.playlistCount(comparison: comparison, count: presetCount))
        }
      }
      return UIMenu(title: comparison.displayText.capitalizedFirstLetter, children: actions)
    }
    return UIMenu(title: "In\u{2026}", children: comparisonMenus)
  }

  // MARK: - Helpers

  private static func dayCountTitle(_ days: Int) -> String {
    switch days {
    case 7: return "7 days"
    case 14: return "14 days"
    case 30: return "30 days"
    case 365: return "1 year"
    default: return "\(days) days"
    }
  }
}

extension String {
  /// Menu titles read better capitalised; the rule model deliberately stores
  /// lower-case fragments ("fewer than") so they compose inside sentences.
  fileprivate var capitalizedFirstLetter: String {
    guard let firstCharacter = first else { return self }
    return String(firstCharacter).uppercased() + dropFirst()
  }
}
