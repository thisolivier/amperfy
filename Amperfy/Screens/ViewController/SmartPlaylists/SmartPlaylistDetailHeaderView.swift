//
//  SmartPlaylistDetailHeaderView.swift
//  Amperfy
//
//  Table header for the Smart Playlists results screen (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistHeaderConfiguration

/// Everything the header renders. Assembled by `SmartPlaylistDetailVC` from the
/// stored `SmartPlaylistState` plus the live refresh status, so the header owns
/// no state of its own and can be reconfigured wholesale on every change.
struct SmartPlaylistHeaderConfiguration {
  /// `query.summaryText` — the one-line rendering of the active rules.
  var querySummaryText: String
  /// First song of the result, whose artwork becomes the preview. `nil` renders
  /// the generated playlist placeholder.
  var artworkSong: Song?
  var themePreference: ThemePreference
  /// When the frozen result was generated; `nil` before the first refresh.
  var refreshedAt: Date?
  var wasOfflineRefresh: Bool
  var isRefreshInProgress: Bool
  /// Live phase line from `SmartPlaylistRefreshPhase.displayText`.
  var refreshStatusText: String?
  /// Caveat footer (missing added-dates, incomplete playlist data, dropped
  /// rules). `nil` hides the label entirely.
  var noteText: String?
  var songCount: Int
}

// MARK: - SmartPlaylistDetailHeaderView

/// The results-screen header, built programmatically (no XIB) because its
/// layout is fork-specific and vertical-stack simple.
///
/// Order is user-specified and deliberate: the artwork preview comes first and
/// the **Refresh button sits directly under it**, because refreshing is the one
/// action this screen exists for — the frozen list never updates itself, so the
/// control that changes it must be the most reachable thing on the page. Play /
/// Shuffle and Edit Query follow underneath.
final class SmartPlaylistDetailHeaderView: UIView {
  // MARK: - Callbacks

  var onRefreshTapped: (() -> ())?
  var onPlayTapped: (() -> ())?
  var onShuffleTapped: (() -> ())?
  var onEditQueryTapped: (() -> ())?

  // MARK: - Subviews

  private static let artworkSideLength: CGFloat = 140.0

  private let contentStackView = UIStackView()
  private let artworkContainerView = UIView()
  private let artworkImageView = EntityImageView(frame: .zero)
  private let placeholderArtworkImageView = UIImageView()
  private let refreshButton = UIButton(configuration: .filled())
  private let refreshStatusLabel = UILabel()
  private let querySummaryLabel = UILabel()
  private let refreshedAtLabel = UILabel()
  private let playShuffleStackView = UIStackView()
  private let playButton = UIButton(configuration: .tinted())
  private let shuffleButton = UIButton(configuration: .tinted())
  private let editQueryButton = UIButton(configuration: .plain())
  private let noteLabel = UILabel()

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Setup

  private func setupSubviews() {
    backgroundColor = .clear
    // The header is a container, never an element itself — see
    // `updateAccessibilityElements()`.
    isAccessibilityElement = false

    contentStackView.translatesAutoresizingMaskIntoConstraints = false
    contentStackView.axis = .vertical
    // `.fill` (not `.center`) so the multi-line labels inherit the stack's width
    // and wrap; the artwork centres itself inside its own full-width container.
    contentStackView.alignment = .fill
    contentStackView.spacing = 12
    addSubview(contentStackView)

    setupArtwork()
    setupRefreshControls()
    setupQueryLabels()
    setupPlaybackControls()
    setupNoteLabel()

    NSLayoutConstraint.activate([
      contentStackView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      contentStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
      contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      contentStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
    ])
  }

  private func setupArtwork() {
    artworkContainerView.translatesAutoresizingMaskIntoConstraints = false
    artworkImageView.translatesAutoresizingMaskIntoConstraints = false
    placeholderArtworkImageView.translatesAutoresizingMaskIntoConstraints = false
    placeholderArtworkImageView.contentMode = .scaleAspectFill
    placeholderArtworkImageView.clipsToBounds = true
    placeholderArtworkImageView.layer.cornerRadius = CornerRadius.small.asCGFloat

    artworkContainerView.addSubview(placeholderArtworkImageView)
    artworkContainerView.addSubview(artworkImageView)
    contentStackView.addArrangedSubview(artworkContainerView)

    NSLayoutConstraint.activate([
      artworkContainerView.heightAnchor.constraint(equalToConstant: Self.artworkSideLength),
      artworkImageView.centerXAnchor.constraint(equalTo: artworkContainerView.centerXAnchor),
      artworkImageView.centerYAnchor.constraint(equalTo: artworkContainerView.centerYAnchor),
      artworkImageView.widthAnchor.constraint(equalToConstant: Self.artworkSideLength),
      artworkImageView.heightAnchor.constraint(equalToConstant: Self.artworkSideLength),
      placeholderArtworkImageView.centerXAnchor
        .constraint(equalTo: artworkContainerView.centerXAnchor),
      placeholderArtworkImageView.centerYAnchor
        .constraint(equalTo: artworkContainerView.centerYAnchor),
      placeholderArtworkImageView.widthAnchor
        .constraint(equalToConstant: Self.artworkSideLength),
      placeholderArtworkImageView.heightAnchor
        .constraint(equalToConstant: Self.artworkSideLength),
    ])
  }

  private func setupRefreshControls() {
    var refreshConfiguration = UIButton.Configuration.filled()
    refreshConfiguration.title = "Refresh"
    refreshConfiguration.image = UIImage(systemName: "arrow.clockwise")
    refreshConfiguration.imagePadding = 8
    refreshConfiguration.cornerStyle = .medium
    refreshConfiguration.buttonSize = .medium
    refreshButton.configuration = refreshConfiguration
    refreshButton.translatesAutoresizingMaskIntoConstraints = false
    refreshButton.addTarget(self, action: #selector(handleRefreshTapped), for: .touchUpInside)
    contentStackView.addArrangedSubview(refreshButton)

    refreshStatusLabel.translatesAutoresizingMaskIntoConstraints = false
    refreshStatusLabel.font = .preferredFont(forTextStyle: .caption1)
    refreshStatusLabel.textColor = .secondaryLabel
    refreshStatusLabel.textAlignment = .center
    refreshStatusLabel.numberOfLines = 1
    contentStackView.addArrangedSubview(refreshStatusLabel)
  }

  private func setupQueryLabels() {
    querySummaryLabel.translatesAutoresizingMaskIntoConstraints = false
    querySummaryLabel.font = .preferredFont(forTextStyle: .subheadline)
    querySummaryLabel.textColor = .label
    querySummaryLabel.textAlignment = .center
    querySummaryLabel.numberOfLines = 0
    contentStackView.addArrangedSubview(querySummaryLabel)

    refreshedAtLabel.translatesAutoresizingMaskIntoConstraints = false
    refreshedAtLabel.font = .preferredFont(forTextStyle: .caption1)
    refreshedAtLabel.textColor = .secondaryLabel
    refreshedAtLabel.textAlignment = .center
    refreshedAtLabel.numberOfLines = 0
    contentStackView.addArrangedSubview(refreshedAtLabel)
  }

  private func setupPlaybackControls() {
    var playConfiguration = UIButton.Configuration.tinted()
    playConfiguration.title = "Play"
    playConfiguration.image = UIImage(systemName: "play.fill")
    playConfiguration.imagePadding = 6
    playConfiguration.cornerStyle = .medium
    playConfiguration.buttonSize = .medium
    playButton.configuration = playConfiguration
    playButton.addTarget(self, action: #selector(handlePlayTapped), for: .touchUpInside)

    var shuffleConfiguration = UIButton.Configuration.tinted()
    shuffleConfiguration.title = "Shuffle"
    shuffleConfiguration.image = UIImage(systemName: "shuffle")
    shuffleConfiguration.imagePadding = 6
    shuffleConfiguration.cornerStyle = .medium
    shuffleConfiguration.buttonSize = .medium
    shuffleButton.configuration = shuffleConfiguration
    shuffleButton.addTarget(self, action: #selector(handleShuffleTapped), for: .touchUpInside)

    playShuffleStackView.translatesAutoresizingMaskIntoConstraints = false
    playShuffleStackView.axis = .horizontal
    playShuffleStackView.distribution = .fillEqually
    playShuffleStackView.spacing = 12
    playShuffleStackView.addArrangedSubview(playButton)
    playShuffleStackView.addArrangedSubview(shuffleButton)
    contentStackView.addArrangedSubview(playShuffleStackView)

    var editQueryConfiguration = UIButton.Configuration.plain()
    editQueryConfiguration.title = "Edit Query"
    editQueryConfiguration.image = UIImage(systemName: "slider.horizontal.3")
    editQueryConfiguration.imagePadding = 6
    editQueryConfiguration.buttonSize = .small
    editQueryButton.configuration = editQueryConfiguration
    editQueryButton.addTarget(self, action: #selector(handleEditQueryTapped), for: .touchUpInside)
    contentStackView.addArrangedSubview(editQueryButton)
  }

  private func setupNoteLabel() {
    noteLabel.translatesAutoresizingMaskIntoConstraints = false
    noteLabel.font = .preferredFont(forTextStyle: .caption2)
    noteLabel.textColor = .secondaryLabel
    noteLabel.textAlignment = .center
    noteLabel.numberOfLines = 0
    contentStackView.addArrangedSubview(noteLabel)
  }

  // MARK: - Configuration

  func configure(with configuration: SmartPlaylistHeaderConfiguration) {
    configureArtwork(with: configuration)

    refreshButton.isEnabled = !configuration.isRefreshInProgress
    refreshButton.configuration?.showsActivityIndicator = configuration.isRefreshInProgress
    refreshButton.configuration?.title = configuration
      .isRefreshInProgress ? "Refreshing" : "Refresh"

    refreshStatusLabel.text = configuration.refreshStatusText
    refreshStatusLabel.isHidden = (configuration.refreshStatusText ?? "").isEmpty

    querySummaryLabel.text = configuration.querySummaryText
    refreshedAtLabel.text = Self.refreshedAtText(for: configuration)

    let hasPlayableSongs = configuration.songCount > 0
    playButton.isEnabled = hasPlayableSongs
    shuffleButton.isEnabled = hasPlayableSongs

    noteLabel.text = configuration.noteText
    noteLabel.isHidden = (configuration.noteText ?? "").isEmpty

    updateAccessibilityElements()
  }

  /// Publishes the header's controls and text in reading order.
  ///
  /// Set explicitly because the header lives inside a table view that stops
  /// vending subviews to accessibility when it has no rows (BUG-3): the
  /// controller hands this whole view to `tableView.accessibilityElements` in
  /// that state, and an explicit list guarantees Refresh and Edit Query are
  /// reachable rather than depending on default subview traversal. Hidden
  /// labels are dropped so VoiceOver never reads a blank or stale line; the
  /// artwork is decorative and stays out.
  private func updateAccessibilityElements() {
    let candidateElements: [UIView] = [
      refreshButton,
      refreshStatusLabel,
      querySummaryLabel,
      refreshedAtLabel,
      playButton,
      shuffleButton,
      editQueryButton,
      noteLabel,
    ]
    accessibilityElements = candidateElements.filter { candidateElement in
      guard !candidateElement.isHidden else { return false }
      guard let label = candidateElement as? UILabel else { return true }
      return !(label.text ?? "").isEmpty
    }
  }

  private func configureArtwork(with configuration: SmartPlaylistHeaderConfiguration) {
    if let artworkSong = configuration.artworkSong {
      artworkImageView.isHidden = false
      placeholderArtworkImageView.isHidden = true
      artworkImageView.display(theme: configuration.themePreference, container: artworkSong)
    } else {
      artworkImageView.isHidden = true
      placeholderArtworkImageView.isHidden = false
      placeholderArtworkImageView.image = UIImage.getGeneratedArtwork(
        theme: configuration.themePreference,
        artworkType: .playlist
      )
    }
  }

  /// "Refreshed 5 minutes ago", plus the offline provenance tag when the last
  /// refresh never reached the server (the result may be missing songs the
  /// device has not synced yet).
  private static func refreshedAtText(
    for configuration: SmartPlaylistHeaderConfiguration,
    now: Date = Date()
  )
    -> String {
    guard let refreshedAt = configuration.refreshedAt else {
      return "Never refreshed"
    }
    let relativeText = relativeRefreshedText(for: refreshedAt, now: now)
    let songCountText = configuration.songCount == 1 ? "1 song" : "\(configuration.songCount) songs"
    var text = "Refreshed \(relativeText) · \(songCountText)"
    if configuration.wasOfflineRefresh {
      text += " · Offline"
    }
    return text
  }

  /// "just now" for anything under a minute old, otherwise the system's
  /// relative phrasing. `RelativeDateTimeFormatter` renders a fresh refresh as
  /// "in 0 seconds" / "0 seconds ago", which reads as broken right after the
  /// one action this screen exists for.
  static func relativeRefreshedText(for refreshedAt: Date, now: Date = Date()) -> String {
    let secondsSinceRefresh = now.timeIntervalSince(refreshedAt)
    guard secondsSinceRefresh >= 60 else { return "just now" }
    return relativeDateFormatter.localizedString(for: refreshedAt, relativeTo: now)
  }

  // MARK: - Actions

  @objc
  private func handleRefreshTapped() { onRefreshTapped?() }

  @objc
  private func handlePlayTapped() { onPlayTapped?() }

  @objc
  private func handleShuffleTapped() { onShuffleTapped?() }

  @objc
  private func handleEditQueryTapped() { onEditQueryTapped?() }
}
