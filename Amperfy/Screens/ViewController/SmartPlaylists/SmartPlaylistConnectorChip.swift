//
//  SmartPlaylistConnectorChip.swift
//  Amperfy
//
//  The and/or connector chip that joins two adjacent items of one query level
//  (V1.5 addendum §1, 2026-08-17).
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

// MARK: - SmartPlaylistConnectorChipButton

/// The tappable "and" / "or" pill.
///
/// A level is always uniform — pure AND or pure OR — so every chip at a level
/// renders the same word and a tap on any of them flips all of them. The chip
/// therefore needs no identity of its own beyond the container it speaks for,
/// which the owning view passes in as a toggle closure.
final class SmartPlaylistConnectorChipButton: UIButton {
  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    var chipConfiguration = UIButton.Configuration.gray()
    chipConfiguration.cornerStyle = .capsule
    chipConfiguration.buttonSize = .small
    chipConfiguration.image = UIImage(systemName: "arrow.left.arrow.right")
    chipConfiguration.imagePadding = 5
    chipConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      scale: .small
    )
    configuration = chipConfiguration
    addTarget(self, action: #selector(handleChipTapped), for: .touchUpInside)
    // The pill is small on purpose; the tap target must not be.
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var onToggle: (() -> ())?

  /// - Parameter levelDescription: what the chip speaks for, spoken by
  ///   VoiceOver before the action ("Group" inside a group card, empty at the
  ///   top level).
  func configure(
    combinator: SmartPlaylistCombinator,
    levelDescription: String,
    onToggle: @escaping () -> ()
  ) {
    configuration?.title = combinator.conjunctionText
    self.onToggle = onToggle

    // Spoken as the ACTION, not as the bare word: "and" on its own tells a
    // VoiceOver user nothing about what tapping would do, and the two words
    // ("and" / "or") are far less distinct by ear than "all" / "any".
    let targetQuantifier = combinator.toggled == .all ? "all" : "any"
    let currentQuantifier = combinator == .all ? "all" : "any"
    let actionLabel = "Change to \(targetQuantifier)"
    accessibilityLabel = levelDescription.isEmpty
      ? actionLabel
      : "\(levelDescription), \(actionLabel)"
    accessibilityValue = "Currently \(currentQuantifier)"
  }

  @objc
  private func handleChipTapped() {
    onToggle?()
  }
}

// MARK: - SmartPlaylistConnectorChipHeaderView

/// The top level's chip, which lives in a section header because each top-level
/// item is its own inset card and the only space between two cards belongs to
/// the following section's header.
final class SmartPlaylistConnectorChipHeaderView: UITableViewHeaderFooterView {
  static let reuseIdentifier = "SmartPlaylistConnectorChipHeader"

  private let chipButton = SmartPlaylistConnectorChipButton()

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    contentView.addSubview(chipButton)
    NSLayoutConstraint.activate([
      chipButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      chipButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      chipButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
    ])
    // The header is a container. Publishing it as one element would swallow the
    // chip and leave the level's combinator unreachable and unchangeable.
    isAccessibilityElement = false
    accessibilityElements = [chipButton]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    combinator: SmartPlaylistCombinator,
    onToggle: @escaping () -> ()
  ) {
    chipButton.configure(combinator: combinator, levelDescription: "", onToggle: onToggle)
  }
}

// MARK: - SmartPlaylistConnectorChipCell

/// A group's internal chip. Inside a card the items are ordinary rows, so the
/// chip between them is an ordinary row too.
final class SmartPlaylistConnectorChipCell: UITableViewCell {
  private let chipButton = SmartPlaylistConnectorChipButton()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    contentView.addSubview(chipButton)
    NSLayoutConstraint.activate([
      chipButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      chipButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      chipButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
    isAccessibilityElement = false
    accessibilityElements = [chipButton]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    combinator: SmartPlaylistCombinator,
    onToggle: @escaping () -> ()
  ) {
    chipButton.configure(
      combinator: combinator,
      levelDescription: "Group",
      onToggle: onToggle
    )
  }
}
