//
//  SongTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

typealias GetPlayContextFromTableCellCallback = (UITableViewCell) -> PlayContext?
typealias GetPlayerIndexFromTableCellCallback = (PlayableTableCell) -> PlayerIndex?

// MARK: - DisplayMode

enum DisplayMode {
  case normal
  case selection
  case reorder
  case add
}

// MARK: - PlayableTableCellStyle

enum PlayableTableCellStyle {
  case none
  case trackNumber
  case artwork
}

// MARK: - PlayableTableCell

@MainActor
class PlayableTableCell: BasicTableCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var artistLabel: UILabel!
  @IBOutlet
  weak var durationLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var trackNumberLabel: UILabel!
  @IBOutlet
  weak private var favoriteIconImage: UIImageView!

  @IBOutlet
  weak var titleContainerLeadingConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var labelTrailingCellConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var durationTrailingCellConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var optionsButton: UIButton!
  @IBOutlet
  weak var deleteButton: UIButton!

  /// Onward-exploration button (SF `chevron.right` in a circular background), a
  /// fork addition (2026-07) sitting to the RIGHT of `optionsButton` in the
  /// trailing pair (user redesign 2026-07-10). Its menu is the exploration-only
  /// slice (Show Album/Artist/Playlists/Lyrics + Related Tracks); `optionsButton`
  /// keeps everything else. Created lazily and hosted in `trailingButtonStack`.
  private var exploreButton: UIButton?
  /// Horizontal stack that wraps `[optionsButton, exploreButton]` — options (…)
  /// on the LEFT, exploration arrow on the RIGHT — so the two identically-sized
  /// circular trailing buttons lay out together. Built once, on first `refresh`.
  private var trailingButtonStack: UIStackView?
  /// Diameter of each circular trailing button (both identical, user redesign).
  private static let trailingButtonDiameter: CGFloat = 30.0
  /// Spacing between the two trailing circular buttons.
  private static let trailingButtonSpacing: CGFloat = 6.0
  /// Width reserved on the trailing edge for the button column: one button
  /// normally, two (options + chevron) when the exploration button shows.
  private var trailingButtonColumnWidth: CGFloat {
    let one = Self.trailingButtonDiameter
    return (exploreButton?.isHidden == false)
      ? (one * 2 + Self.trailingButtonSpacing)
      : one
  }

  /// A small semi-opaque dot rendered on the LEFT edge of the album art
  /// (extending into the left margin) marking a downloaded/cached track — the
  /// user redesign (2026-07-10) that moves the cached signal OFF the trailing
  /// area. Lazily added as a subview of `entityImage`.
  private var cachedDotView: UIView?
  private static let cachedDotDiameter: CGFloat = 10.0
  /// Whether this cell has registered for the download-finished notification
  /// (guards against double-registration across reuse).
  private var isDownloadObserverRegistered = false
  /// Retained so its per-account `.downloadFinishedSuccess` registrations live
  /// for the cell's lifetime.
  private var downloadAccountNotificationHandler: AccountNotificationHandler?

  @IBOutlet
  weak var playOverArtworkButton: UIButton!
  @IBOutlet
  weak var playOverNumberButton: UIButton!

  private var ratingStackView: UIStackView?
  private var ratingStarViews: [UIImageView] = []

  static let rowHeight: CGFloat = 48 + margin.bottom + margin.top
  private static let touchAnimation = 0.4

  private var style = PlayableTableCellStyle.none
  private var playerIndexCb: GetPlayerIndexFromTableCellCallback?
  private var playContextCb: GetPlayContextFromTableCellCallback?
  private(set) var playable: AbstractPlayable?
  private var download: Download?
  private var rootView: UIViewController?
  private var playIndicator: PlayIndicator?
  private var isDislayAlbumTrackNumberStyle: Bool = false
  private var displayMode: DisplayMode = .normal
  #if targetEnvironment(macCatalyst) // ok
    private var hoverGestureRecognizer: UIHoverGestureRecognizer!
    private var doubleTapGestureRecognizer: UITapGestureRecognizer!
    private var isHovered = false
    private var isNotificationRegistered = false
  #else
    private var singleTapGestureRecognizer: UITapGestureRecognizer!
  #endif

  public var isMarked = false
  private var isDeleteButtonAllowedToBeVisible: Bool {
    (traitCollection.userInterfaceIdiom == .mac) && (playerIndexCb != nil)
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    // This must be called in Main thread
    MainActor.assumeIsolated {
      playContextCb = nil
      #if targetEnvironment(macCatalyst) // ok
        hoverGestureRecognizer = UIHoverGestureRecognizer(
          target: self,
          action: #selector(hovering(_:))
        )
        self.addGestureRecognizer(hoverGestureRecognizer)
        isHovered = false
        doubleTapGestureRecognizer = UITapGestureRecognizer(
          target: self,
          action: #selector(doubleTap)
        )
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        self.addGestureRecognizer(doubleTapGestureRecognizer)
      #else
        singleTapGestureRecognizer = UITapGestureRecognizer(
          target: self,
          action: #selector(singleTap)
        )
        singleTapGestureRecognizer.numberOfTapsRequired = 1
        // to handle double and single tap recognizer in parallel:
        // singleTapGestureRecognizer.require(toFail: doubleTapGestureRecognizer)
        self.addGestureRecognizer(singleTapGestureRecognizer)
      #endif

      style = PlayableTableCellStyle.none
      deleteButton.tintColor = .red
      playOverArtworkButton.layer.backgroundColor = UIColor.imageOverlayBackground.cgColor
      playOverArtworkButton.layer.cornerRadius = CornerRadius.small.asCGFloat
      selectionStyle = .none
      setupTrailingButtonStack()
      setupRatingStars()
      resetForReuse()
    }
  }

  /// Rehome `optionsButton` (xib-pinned to the trailing margin) into a
  /// horizontal `UIStackView` alongside a new `chevron.right` exploration
  /// button. The xib's single-occupancy trailing slot becomes a two-button
  /// column; the exploration button is hidden by default and only shown for
  /// song rows in `refreshCacheAndDuration`. checkmark / reorder /
  /// download-progress (`accessoryView`) and the Mac Catalyst delete button are
  /// untouched — they live outside this stack.
  private func setupTrailingButtonStack() {
    // Deactivate the xib trailing-margin pin on optionsButton so the stack can
    // own the trailing edge instead. (Constraint id X7z-Kg-90N.)
    for constraint in contentView.constraints where
      (constraint.firstItem === optionsButton || constraint.secondItem === optionsButton) &&
      (constraint.firstAttribute == .trailing || constraint.firstAttribute == .trailingMargin) {
      constraint.isActive = false
    }

    // User redesign (2026-07-10): both trailing controls sit in identical
    // circular backgrounds. `…` (options) on the LEFT, exploration arrow on the
    // RIGHT. Style the xib-provided options button to match the new explore one.
    let diameter = Self.trailingButtonDiameter
    styleCircularTrailingButton(
      optionsButton,
      systemImageName: "ellipsis",
      accessibilityLabel: "More Actions"
    )

    let chevron = UIButton(type: .system)
    chevron.translatesAutoresizingMaskIntoConstraints = false
    styleCircularTrailingButton(
      chevron,
      systemImageName: "chevron.right",
      accessibilityLabel: "Explore"
    )
    chevron.showsMenuAsPrimaryAction = true
    chevron.isHidden = true
    NSLayoutConstraint.activate([
      chevron.widthAnchor.constraint(equalToConstant: diameter),
      chevron.heightAnchor.constraint(equalToConstant: diameter),
    ])
    exploreButton = chevron

    // options (…) LEFT, explore (arrow) RIGHT.
    let stack = UIStackView(arrangedSubviews: [optionsButton, chevron])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .fill
    stack.spacing = Self.trailingButtonSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      optionsButton.widthAnchor.constraint(equalToConstant: diameter),
      optionsButton.heightAnchor.constraint(equalToConstant: diameter),
    ])
    trailingButtonStack = stack
  }

  /// Give a trailing button the shared circular-background look: a fixed-size
  /// tinted circle with a centered SF Symbol glyph. Both `…` and the exploration
  /// arrow use this so they are visually identical (user redesign 2026-07-10).
  private func styleCircularTrailingButton(
    _ button: UIButton,
    systemImageName: String,
    accessibilityLabel: String
  ) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: systemImageName)
    config.background.backgroundColor = .secondarySystemFill
    config.background.cornerRadius = Self.trailingButtonDiameter / 2
    config.contentInsets = .zero
    button.configuration = config
    button.tintColor = .secondaryLabel
    button.accessibilityLabel = accessibilityLabel
    button.layer.cornerRadius = Self.trailingButtonDiameter / 2
    button.clipsToBounds = true
  }

  /// Lazily build the cached-state dot on the LEFT edge of the album art. It sits
  /// slightly into the left margin (negative leading) and vertically centered.
  private func setupCachedDotIfNeeded() {
    guard cachedDotView == nil else { return }
    let dot = UIView()
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.backgroundColor = UIColor.label.withAlphaComponent(0.55)
    dot.layer.cornerRadius = Self.cachedDotDiameter / 2
    dot.layer.borderWidth = 1
    dot.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.9).cgColor
    dot.isUserInteractionEnabled = false
    dot.isHidden = true
    dot.isAccessibilityElement = false
    entityImage.addSubview(dot)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: Self.cachedDotDiameter),
      dot.heightAnchor.constraint(equalToConstant: Self.cachedDotDiameter),
      // Extend into the left margin: centre the dot on the art's leading edge.
      dot.centerXAnchor.constraint(equalTo: entityImage.leadingAnchor),
      dot.centerYAnchor.constraint(equalTo: entityImage.centerYAnchor),
    ])
    entityImage.clipsToBounds = false
    cachedDotView = dot
  }

  private func setupRatingStars() {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.spacing = -2 // Negative spacing to put stars closer together
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false

    // Create 5 star image views
    for _ in 0 ..< 5 {
      let starView = UIImageView()
      starView.contentMode = .scaleAspectFit
      starView.translatesAutoresizingMaskIntoConstraints = false
      starView.image = .starEmpty
      starView.tintColor = UIColor(red: 0.882, green: 0.686, blue: 0.255, alpha: 1.0) // #e1af41
      let starSize: CGFloat = 10
      NSLayoutConstraint.activate([
        starView.widthAnchor.constraint(equalToConstant: starSize),
        starView.heightAnchor.constraint(equalToConstant: starSize),
      ])
      ratingStarViews.append(starView)
      stackView.addArrangedSubview(starView)
    }

    contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.trailingAnchor.constraint(equalTo: optionsButton.trailingAnchor, constant: -4),
      stackView.topAnchor.constraint(equalTo: optionsButton.bottomAnchor, constant: -8),
    ])

    ratingStackView = stackView
  }

  private func updateRatingDisplay(rating: Int) {
    // Show the LAST N stars (right-aligned) instead of first N
    // This keeps stars right-justified regardless of rating
    let startIndex = 5 - rating
    for (index, starView) in ratingStarViews.enumerated() {
      starView.isHidden = index < startIndex
      starView.image = .starFill
    }

    // Only show rating if song has a rating > 0
    ratingStackView?.isHidden = (rating == 0)
  }

  func resetForReuse() {
    playIndicator?.reset()
    exploreButton?.isHidden = true
    deleteButton.isHidden = true
    playOverArtworkButton.isHidden = true
    playOverNumberButton.isHidden = true
    ratingStackView?.isHidden = true
    // Reset all stars for next use
    for starView in ratingStarViews {
      starView.isHidden = false
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    resetForReuse()
  }

  #if targetEnvironment(macCatalyst) // ok
    private func register() {
      guard !isNotificationRegistered else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerPlay(notification:)),
        name: .playerPlay,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerPause(notification:)),
        name: .playerPause,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerStop(notification:)),
        name: .playerStop,
        object: nil
      )
      isNotificationRegistered = true
    }
  #endif

  func display(
    playable: AbstractPlayable,
    displayMode: DisplayMode = .normal,
    playContextCb: GetPlayContextFromTableCellCallback?,
    rootView: UIViewController,
    playerIndexCb: GetPlayerIndexFromTableCellCallback? = nil,
    isDislayAlbumTrackNumberStyle: Bool = false,
    download: Download? = nil,
    isMarked: Bool = false
  ) {
    if playIndicator?.rootViewTypeName != rootView.typeName {
      playIndicator = PlayIndicator(rootViewTypeName: rootView.typeName)
    }

    self.playable = playable
    self.displayMode = displayMode
    self.playContextCb = playContextCb
    self.playerIndexCb = playerIndexCb
    self.rootView = rootView
    self.isDislayAlbumTrackNumberStyle = isDislayAlbumTrackNumberStyle
    self.download = download
    self.isMarked = isMarked

    #if targetEnvironment(macCatalyst) // ok
      hoverGestureRecognizer.isEnabled = (displayMode == .normal)
      isHovered = false
      doubleTapGestureRecognizer.isEnabled = (displayMode == .normal)
      register()
    #else
      singleTapGestureRecognizer.isEnabled = (displayMode == .normal)
    #endif
    backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground
    registerForDownloadFinishIfNeeded()
    refresh()
  }

  /// Observe download completion so the cached dot (and any accessory) refresh
  /// LIVE on the visible cell (QA A-P2-1: the indicator previously only updated
  /// after leaving and re-entering the view). Registered once per cell against
  /// all accounts' playable download managers; the handler filters by the
  /// displayed playable's uniqueID.
  private func registerForDownloadFinishIfNeeded() {
    guard !isDownloadObserverRegistered else { return }
    isDownloadObserverRegistered = true
    let accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
    // Retain the handler for the cell's lifetime so its per-account
    // registrations stay live.
    downloadAccountNotificationHandler = accountNotificationHandler
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let playable = playable,
          playable.uniqueID == downloadNotification.id
    else { return }
    // The download just landed — refresh the visible cell so the cached dot
    // (and any download accessory) reflect the new state immediately.
    refresh()
  }

  private func configureStyle(playable: AbstractPlayable, newStyle: PlayableTableCellStyle) {
    // adjust style only if it has changed
    guard newStyle != style else { return }

    switch newStyle {
    case .trackNumber:
      configureTrackNumberLabel()
      playIndicator?.willDisplayIndicatorCB = { [weak self] () in
        guard let self = self else { return }
        trackNumberLabel.text = ""
      }
      playIndicator?.willHideIndicatorCB = { [weak self] () in
        guard let self = self else { return }
        configureTrackNumberLabel()
      }
      trackNumberLabel.isHidden = false
      entityImage.isHidden = true
      titleContainerLeadingConstraint.constant = 10 + 21 + 16 // heart + track lable width + offset
    case .artwork:
      playIndicator?.willDisplayIndicatorCB = nil
      playIndicator?.willHideIndicatorCB = nil
      trackNumberLabel.isHidden = true
      entityImage.isHidden = false
      titleContainerLeadingConstraint.constant = 10 + 48 + 8 // heart + artwork width + offset
    case .none:
      break // do nothing
    }
  }

  private func configurePlayIndicator(playable: AbstractPlayable?) {
    guard let playable = playable else {
      playIndicator?.reset()
      return
    }

    if isDislayAlbumTrackNumberStyle {
      playIndicator?.display(playable: playable, rootView: trackNumberLabel)
    } else {
      if playerIndexCb == nil {
        playIndicator?.display(playable: playable, rootView: entityImage, isOnImage: true)
      } else {
        // don't show play indicator on PopupPlayer
        playIndicator?.reset()
      }
    }
  }

  func refresh() {
    guard let playable = playable else { return }
    titleLabel.text = playable.title
    artistLabel.text = playable.creatorName

    configureStyle(
      playable: playable,
      newStyle: isDislayAlbumTrackNumberStyle ? .trackNumber : .artwork
    )
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(playable.account?.info).read
        .themePreference,
      container: playable
    )
    configurePlayIndicator(playable: playable)

    if displayMode == .selection {
      let img = UIImageView(image: isMarked ? .checkmark : .circle)
      img.tintColor = isMarked ? appDelegate.storage.settings.accounts
        .getSetting(playable.account?.info).read
        .themePreference
        .asColor : .secondaryLabelColor
      accessoryView = img
    } else if displayMode == .add {
      let img = UIImageView(image: isMarked ? .checkmark : .plusCircle)
      img.tintColor = appDelegate.storage.settings.accounts.getSetting(playable.account?.info).read
        .themePreference
        .asColor
      accessoryView = img
    } else if displayMode == .reorder || playerIndexCb != nil {
      let img = UIImageView(image: .bars)
      img.tintColor = .labelColor
      accessoryView = img
    } else if let download = download {
      if download.error != nil {
        let img = UIImageView(image: .exclamation)
        img.tintColor = .labelColor
        accessoryView = img
      } else if download.isFinishedSuccessfully {
        let img = UIImageView(image: .check)
        img.tintColor = .labelColor
        accessoryView = img
      } else if download.isDownloading {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.tintColor = .labelColor
        accessoryView = spinner
      } else {
        accessoryView = nil
      }
    } else {
      accessoryView = nil
    }

    refreshSubtitleColor()
    refreshCacheAndDuration()

    // Update rating display for songs (only if setting is enabled)
    if appDelegate.storage.settings.user.isShowRating, let song = playable.asSong {
      updateRatingDisplay(rating: song.rating)
    } else {
      ratingStackView?.isHidden = true
    }

    refreshAccessibilityValue()
  }

  /// Compose a single spoken accessibilityValue for the whole cell covering the
  /// states VoiceOver would otherwise miss: the cached dot is decorative
  /// (`isAccessibilityElement = false`), the favorite heart is a bare tinted
  /// glyph, and the download accessory is a spinner/checkmark/exclamation with
  /// no label. Rolling them into the cell's value means one swipe announces
  /// "<title>, <artist>, Downloaded, Favorite, Downloading" rather than the
  /// title alone. Order mirrors the visual reading order (leading dot → heart →
  /// trailing accessory).
  private func refreshAccessibilityValue() {
    guard let playable else {
      accessibilityValue = nil
      return
    }
    var spokenStates: [String] = []
    if playable.isCached {
      spokenStates.append("Downloaded")
    }
    if playable.isFavorite {
      spokenStates.append("Favorite")
    }
    if let download {
      if download.error != nil {
        spokenStates.append("Download failed")
      } else if download.isDownloading {
        spokenStates.append("Downloading")
      } else if download.isFinishedSuccessfully, !playable.isCached {
        // Avoid saying "Downloaded" twice when isCached already covers it.
        spokenStates.append("Downloaded")
      }
    }
    accessibilityValue = spokenStates.isEmpty ? nil : spokenStates.joined(separator: ", ")
  }

  private func configureTrackNumberLabel() {
    guard let playable = playable else { return }
    trackNumberLabel.text = playable.track > 0 ? "\(playable.track)" : ""
  }

  func refreshCacheAndDuration() {
    guard let playable = playable else { return }
    favoriteIconImage.isHidden = !playable.isFavorite
    favoriteIconImage.tintColor = .red

    let isDurationVisible = !playable.isRadio &&
      (
        appDelegate.storage.settings.user
          .isShowSongDuration || (traitCollection.horizontalSizeClass == .regular)
      )
    let durationWidth = (
      traitCollection.horizontalSizeClass == .regular &&
        traitCollection.userInterfaceIdiom != .mac
    ) ? 49.0 : 40.0
    let isDisplayOptionButton = (playContextCb != nil) && (playerIndexCb == nil)

    // The exploration chevron shows only for real song rows in a browse
    // context (never in the queue/PopupPlayer reorder surface, where
    // playerIndexCb is set), and only when there is at least one onward
    // destination to offer. When shown, `…` drops the exploration items and
    // becomes actions-only; when hidden, `…` keeps the full combined menu.
    let isDisplayExploreButton = isDisplayOptionButton && (playable.asSong != nil)
    exploreButton?.isHidden = !isDisplayExploreButton

    // Reserve one column (30) normally, two (chevron + options = 60) when the
    // exploration button is shown, so labels/cache/duration clear both buttons.
    let durationTrailing = isDisplayOptionButton ? trailingButtonColumnWidth : 0.0

    optionsButton.isHidden = !isDisplayOptionButton
    if isDisplayOptionButton {
      optionsButton.showsMenuAsPrimaryAction = true
      optionsButton.imageView?.tintColor = .label
      if let rootView = rootView {
        let playContext = playContextCb != nil ? { self.playContextCb?(self) } : nil
        let playIndex = playerIndexCb != nil ? { self.playerIndexCb?(self) } : nil
        // Options menu: actions-only when the chevron carries exploration,
        // otherwise the historical full combined menu.
        let optionsMenuMode: EntityMenuMode = isDisplayExploreButton ? .actionsOnly : .full
        optionsButton.menu = UIMenu.lazyMenu {
          EntityPreviewActionBuilder(
            container: playable,
            on: rootView,
            playContextCb: playContext,
            playerIndexCb: playIndex,
            menuMode: optionsMenuMode
          ).createMenuActions()
        }
        // Chevron menu: exploration-only.
        if isDisplayExploreButton {
          exploreButton?.menu = UIMenu.lazyMenu {
            EntityPreviewActionBuilder(
              container: playable,
              on: rootView,
              playContextCb: playContext,
              playerIndexCb: playIndex,
              menuMode: .explorationOnly
            ).createMenuActions()
          }
        }
      }
    }

    // macOS & iPadOS regular
    // |title|x|Cache|4|Duration| ... |
    // |title|        80        | 30  |
    // compact
    // |title|4|Cache|4|Duration| ... |
    // |title|4|  15 |4|   40   | 30  |
    // |title|4|  15 |-|   --   | 30  |
    // |title|8|  -- |-|   40   | 30  |
    // Calculate extra space needed for rating stars when duration is hidden
    // Stars are positioned at optionsButton.trailingAnchor - 4, extending left
    // Each star is 10pt with -2pt spacing: width = rating * 8 + 2
    // We only need extra space beyond what optionsButton area (30pt) already provides
    let songRating = playable.asSong?.rating ?? 0
    let isRatingVisible = appDelegate.storage.settings.user.isShowRating && songRating > 0
    let starWidth = CGFloat(songRating * 8 + 2) // Actual star width for this rating
    let ratingExtraSpace: CGFloat = isRatingVisible ? max(0, starWidth - 26) + 6 : 0.0

    // The cached signal now lives as a dot on the LEFT of the album art (user
    // redesign 2026-07-10), so the trailing area no longer reserves width for a
    // cache glyph — only the duration (when shown) still claims trailing space.
    if traitCollection.horizontalSizeClass == .regular {
      labelTrailingCellConstraint.constant = 80 + durationTrailing
    } else {
      var lableTrailing = durationTrailing
      if isDurationVisible {
        lableTrailing += 8 + durationWidth
      }
      // Add extra space for rating stars when duration is not visible
      if !isDurationVisible, isRatingVisible {
        lableTrailing += ratingExtraSpace
      }
      labelTrailingCellConstraint.constant = lableTrailing
    }

    durationTrailingCellConstraint.constant = durationTrailing
    // The cached signal is a dot on the LEFT of the album art (user redesign
    // 2026-07-10); the old trailing cache glyph and its constraint are gone.
    setupCachedDotIfNeeded()
    updateCachedDot()
    durationLabel.isHidden = !isDurationVisible
    if isDurationVisible {
      durationLabel.text = playable.duration.asColonDurationString
    }
  }

  /// Show the left-of-artwork cached dot only for downloaded/cached tracks, and
  /// only in the artwork style (there is no album art in the track-number
  /// style, so no anchor for the dot).
  private func updateCachedDot() {
    let showDot = (playable?.isCached ?? false)
      && !isDislayAlbumTrackNumberStyle
      && !entityImage.isHidden
    cachedDotView?.isHidden = !showDot
  }

  private func refreshSubtitleColor() {
    let primaryColor = ThemeStore.shared.dynamicText ?? UIColor.labelColor
    let secondaryColor = ThemeStore.shared.dynamicSecondaryText ?? UIColor.secondaryLabelColor
    if playerIndexCb != nil {
      artistLabel.textColor = primaryColor
      durationLabel.textColor = primaryColor
    } else {
      artistLabel.textColor = secondaryColor
      durationLabel.textColor = secondaryColor
    }
  }

  func playThisSong() {
    guard let playable = playable else { return }
    if let playerIndex = playerIndexCb?(self) {
      appDelegate.player.play(playerIndex: playerIndex)
    } else if let context = playContextCb?(self),
              playable.isCached || appDelegate.storage.settings.user.isOnlineMode {
      animateActivation()
      hideSearchBarKeyboardInRootView()
      Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
      appDelegate.player.play(context: context)
    }
  }

  private func hideSearchBarKeyboardInRootView() {
    if let basicRootView = rootView as? BasicTableViewController {
      basicRootView.searchController.searchBar.endEditing(true)
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    playIndicator?.applyStyle()
  }

  #if targetEnvironment(macCatalyst) // ok
    @IBAction
    func deleteButtonPressed(_ sender: Any) {
      if let playerIndexCb = playerIndexCb,
         let playerIndex = playerIndexCb(self),
         let queueVC = rootView as? QueueVC,
         let tableView = queueVC.tableView {
        queueVC.tableView(tableView, commit: .delete, forRowAt: playerIndex.asIndexPath)
      }
      if let playerIndexCb = playerIndexCb,
         let playerIndex = playerIndexCb(self),
         let popupPlayerVC = rootView as? PopupPlayerVC,
         let tableView = popupPlayerVC.tableView {
        popupPlayerVC.tableView(tableView, commit: .delete, forRowAt: playerIndex.asIndexPath)
      }
    }

    @IBAction
    func playButtonPressed(_ sender: Any) {
      if appDelegate.player.currentlyPlaying == playable,
         appDelegate.player.isPlaying {
        appDelegate.player.pause()
      } else if appDelegate.player.currentlyPlaying == playable {
        appDelegate.player.play()
      } else {
        playThisSong()
      }
      refreshHoverStyle()
    }

    func refreshHoverStyle() {
      if isHovered {
        playIndicator?.reset()
        if isDeleteButtonAllowedToBeVisible {
          deleteButton.isHidden = false
        } else {
          var buttonImg = UIImage()
          if appDelegate.player.currentlyPlaying == playable,
             appDelegate.player.isPlaying {
            if appDelegate.player.isStopInsteadOfPause {
              buttonImg = UIImage.stop
            } else {
              buttonImg = UIImage.pause
            }
          } else {
            buttonImg = UIImage.play
          }
          if isDislayAlbumTrackNumberStyle {
            trackNumberLabel.isHidden = true
            playOverNumberButton.isHidden = false
            playOverNumberButton.imageView?.tintColor = appDelegate.storage.settings.accounts
              .getSetting(playable?.account?.info).read.themePreference
              .asColor
            playOverNumberButton.setImage(buttonImg, for: UIControl.State.normal)
            playOverArtworkButton.isHidden = true
          } else {
            playOverArtworkButton.isHidden = false
            playOverArtworkButton.imageView?.tintColor = .white
            playOverArtworkButton.setImage(buttonImg, for: UIControl.State.normal)
            playOverNumberButton.isHidden = true
          }
        }
        optionsButton.imageView?.tintColor = appDelegate.storage.settings.accounts
          .getSetting(playable?.account?.info).read.themePreference.asColor
        backgroundColor = (rootView is PopupPlayerVC) ?
          .secondarySystemGroupedBackground.withAlphaComponent(0.2) :
          .secondarySystemGroupedBackground
      } else {
        playOverArtworkButton.isHidden = true
        playOverNumberButton.isHidden = true
        if isDislayAlbumTrackNumberStyle {
          trackNumberLabel.isHidden = false
        }
        configurePlayIndicator(playable: playable)
        deleteButton.isHidden = true
        refreshSubtitleColor()
        optionsButton.imageView?.tintColor = .label
        backgroundColor = .clear
      }
    }

    @objc
    func hovering(_ recognizer: UIHoverGestureRecognizer) {
      switch recognizer.state {
      case .began:
        isHovered = true
        refreshHoverStyle()
      case .ended:
        isHovered = false
        refreshHoverStyle()
      default:
        if !isHovered {
          isHovered = true
          refreshHoverStyle()
        }
      }
    }

    @objc
    func doubleTap(sender: UITapGestureRecognizer) {
      switch sender.state {
      case .ended:
        if displayMode == .normal {
          playThisSong()
        }
      default:
        break
      }
    }

    @objc
    private func playerPlay(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

    @objc
    private func playerPause(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

    @objc
    private func playerStop(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

  #else

    @objc
    func singleTap(sender: UITapGestureRecognizer) {
      switch sender.state {
      case .ended:
        if displayMode == .normal {
          playThisSong()
        }
      default:
        break
      }
    }
  #endif
}
