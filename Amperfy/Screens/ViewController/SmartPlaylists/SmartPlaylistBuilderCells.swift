//
//  SmartPlaylistBuilderCells.swift
//  Amperfy
//
//  The rows of the smart playlist builder table: rule rows, the group card's
//  header, and the trailing add actions (V1.5 addendum §1, 2026-08-17).
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

// MARK: - SmartPlaylistBuilderStyle

/// The two visual decisions that make a group read as nested: its rows sit a
/// little further in, and its card is a shade off the plain card colour.
@MainActor
enum SmartPlaylistBuilderStyle {
  /// How far a group's rows are pushed in from a top-level rule's.
  static let groupContentIndent: CGFloat = 14.0

  /// The group card's fill.
  ///
  /// Dark mode can use a system colour directly — `tertiarySystemGroupedBackground`
  /// sits one step lighter than the plain card there. Light mode cannot:
  /// `tertiarySystemGroupedBackground` is the same value as the *page*
  /// background, and a neutral grey between the white card (#FFFFFF) and the
  /// page (#F2F2F7) has nowhere to go — on device it read as a hole in the page
  /// rather than a card (QA 2026-08-17). Hence an explicit cool tint: lighter
  /// than the page, unmistakably not the plain white card.
  static let groupCardBackgroundColor = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark
      ? UIColor.tertiarySystemGroupedBackground
      : UIColor(red: 0.918, green: 0.941, blue: 0.980, alpha: 1.0)
  }

  static func applyCardBackground(to cell: UITableViewCell, isInsideGroupCard: Bool) {
    var backgroundConfiguration = UIBackgroundConfiguration.listGroupedCell()
    if isInsideGroupCard {
      backgroundConfiguration.backgroundColor = groupCardBackgroundColor
    }
    cell.backgroundConfiguration = backgroundConfiguration
  }
}

// MARK: - SmartPlaylistRuleCell

/// A rule row rendered as one full-width button so the whole row opens its
/// value menu — the same feel as a pop-up-button form row, and it keeps the
/// cell's swipe-to-delete intact. Also used for the "+ Add rule" row inside a
/// group card.
final class SmartPlaylistRuleCell: UITableViewCell {
  private let rowButton = UIButton(configuration: .plain())
  private var tapAction: (() -> ())?
  private var rowButtonLeadingConstraint: NSLayoutConstraint!

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    rowButton.translatesAutoresizingMaskIntoConstraints = false
    rowButton.contentHorizontalAlignment = .leading
    rowButton.addTarget(self, action: #selector(handleRowButtonTapped), for: .touchUpInside)
    contentView.addSubview(rowButton)
    self.rowButtonLeadingConstraint = rowButton.leadingAnchor
      .constraint(equalTo: contentView.leadingAnchor)
    NSLayoutConstraint.activate([
      rowButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      rowButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      rowButtonLeadingConstraint,
      rowButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configureAsRuleRow(
    title: String,
    subtitle: String,
    menu: UIMenu?,
    contentIndent: CGFloat = 0,
    tapAction: (() -> ())?
  ) {
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.title = title
    buttonConfiguration.subtitle = subtitle
    buttonConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = .preferredFont(forTextStyle: .footnote)
      attributes.foregroundColor = UIColor.secondaryLabel
      return attributes
    }
    buttonConfiguration.subtitleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.font = .preferredFont(forTextStyle: .body)
        attributes.foregroundColor = UIColor.label
        return attributes
      }
    buttonConfiguration.image = UIImage(systemName: "chevron.up.chevron.down")
    buttonConfiguration.imagePlacement = .trailing
    buttonConfiguration.imagePadding = 8
    rowButton.configuration = buttonConfiguration
    rowButton.menu = menu
    rowButton.showsMenuAsPrimaryAction = (menu != nil)
    rowButton.isEnabled = true
    rowButtonLeadingConstraint.constant = contentIndent
    self.tapAction = tapAction
  }

  /// The "+ Add rule" affordance. A `nil` menu means every rule kind this
  /// container accepts is already present, so the row is shown disabled rather
  /// than disappearing — a row that vanishes and reappears is harder to follow
  /// than one that dims.
  func configureAsAddRuleRow(menu: UIMenu?, contentIndent: CGFloat = 0) {
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.title = "Add Rule"
    buttonConfiguration.image = UIImage(systemName: "plus.circle.fill")
    buttonConfiguration.imagePadding = 8
    rowButton.configuration = buttonConfiguration
    rowButton.menu = menu
    rowButton.showsMenuAsPrimaryAction = (menu != nil)
    rowButton.isEnabled = (menu != nil)
    rowButtonLeadingConstraint.constant = contentIndent
    tapAction = nil
  }

  @objc
  private func handleRowButtonTapped() {
    tapAction?()
  }
}

// MARK: - SmartPlaylistGroupHeaderCell

/// The first row of a group card: what the group is, how its rules combine, and
/// the ⋯ menu that changes or removes it.
///
/// The combinator is spelled out here as well as on the chips because a group
/// holding a single rule has no chips at all, and the combinator it will use
/// once a second rule arrives should still be visible and changeable.
final class SmartPlaylistGroupHeaderCell: UITableViewCell {
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let optionsButton = UIButton(configuration: .plain())

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none

    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    iconImageView.image = UIImage(systemName: "curlybraces")
    iconImageView.tintColor = .secondaryLabel
    iconImageView.contentMode = .scaleAspectFit
    iconImageView.setContentHuggingPriority(.required, for: .horizontal)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .preferredFont(forTextStyle: .footnote)
    titleLabel.textColor = .secondaryLabel
    titleLabel.numberOfLines = 0
    titleLabel.isAccessibilityElement = true

    var optionsConfiguration = UIButton.Configuration.plain()
    optionsConfiguration.image = UIImage(systemName: "ellipsis.circle")
    optionsConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 6, leading: 10, bottom: 6, trailing: 12
    )
    optionsButton.configuration = optionsConfiguration
    optionsButton.translatesAutoresizingMaskIntoConstraints = false
    optionsButton.showsMenuAsPrimaryAction = true
    optionsButton.setContentHuggingPriority(.required, for: .horizontal)
    optionsButton.accessibilityLabel = "Group options"

    contentView.addSubview(iconImageView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(optionsButton)

    NSLayoutConstraint.activate([
      iconImageView.leadingAnchor.constraint(
        equalTo: contentView.layoutMarginsGuide.leadingAnchor,
        constant: SmartPlaylistBuilderStyle.groupContentIndent
      ),
      iconImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      optionsButton.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor,
        constant: 8
      ),
      optionsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      optionsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
    ])

    // A container, not an element: publishing the cell itself would hide the ⋯
    // button, which is the only way to remove a group with VoiceOver on.
    isAccessibilityElement = false
    accessibilityElements = [titleLabel, optionsButton]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(combinator: SmartPlaylistCombinator, optionsMenu: UIMenu) {
    let quantifier = combinator == .all ? "all" : "any"
    titleLabel.text = "Group — match \(quantifier)"
    optionsButton.menu = optionsMenu
  }
}

// MARK: - SmartPlaylistBuilderActionsCell

/// The trailing "+ Add rule" / "+ Add group" pair, side by side.
final class SmartPlaylistBuilderActionsCell: UITableViewCell {
  private let addRuleButton = UIButton(configuration: .plain())
  private let addGroupButton = UIButton(configuration: .plain())
  private let buttonStackView = UIStackView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none

    var addRuleConfiguration = UIButton.Configuration.plain()
    addRuleConfiguration.title = "Add Rule"
    addRuleConfiguration.image = UIImage(systemName: "plus.circle.fill")
    addRuleConfiguration.imagePadding = 6
    addRuleButton.configuration = addRuleConfiguration

    var addGroupConfiguration = UIButton.Configuration.plain()
    addGroupConfiguration.title = "Add Group"
    addGroupConfiguration.image = UIImage(systemName: "plus.rectangle.on.rectangle")
    addGroupConfiguration.imagePadding = 6
    addGroupButton.configuration = addGroupConfiguration

    buttonStackView.translatesAutoresizingMaskIntoConstraints = false
    buttonStackView.axis = .horizontal
    buttonStackView.distribution = .fillEqually
    buttonStackView.spacing = 4
    buttonStackView.addArrangedSubview(addRuleButton)
    buttonStackView.addArrangedSubview(addGroupButton)
    contentView.addSubview(buttonStackView)

    NSLayoutConstraint.activate([
      buttonStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      buttonStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      buttonStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      buttonStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])

    isAccessibilityElement = false
    accessibilityElements = [addRuleButton, addGroupButton]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// - Parameters:
  ///   - addRuleMenu: `nil` when the top level already holds every
  ///     single-instance rule kind; the button then dims rather than vanishes.
  ///   - addGroupMenu: the new group's first rule. Choosing one creates the
  ///     group; dismissing the menu creates nothing, which is why an empty group
  ///     can never be left behind by this control.
  func configure(addRuleMenu: UIMenu?, addGroupMenu: UIMenu) {
    addRuleButton.menu = addRuleMenu
    addRuleButton.showsMenuAsPrimaryAction = (addRuleMenu != nil)
    addRuleButton.isEnabled = (addRuleMenu != nil)
    addGroupButton.menu = addGroupMenu
    addGroupButton.showsMenuAsPrimaryAction = true
  }
}
