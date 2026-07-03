//
//  HomeVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 24.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import CoreData
import OSLog
import UIKit

// MARK: - HomeVC

final class HomeVC: UICollectionViewController {
  // MARK: - Properties

  private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeCellItem>!
  private let log = OSLog(subsystem: "Amperfy", category: "HomeVC")

  private static let itemWidth: CGFloat = 160.0

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?
  private let sharedHome: HomeManager

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    self.sharedHome = HomeManager(
      account: account,
      storage: appDelegate.storage,
      getMeta: appDelegate.getMeta,
      eventLogger: appDelegate.eventLogger
    )
    let layout = HomeVC.createLayout()
    super.init(collectionViewLayout: layout)
    sharedHome.applySnapshotCB = { [weak self] in
      guard let self else { return }
      applySnapshot(animated: true)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // ensures that the collection view stops placing items under the sidebar
    collectionView.contentInsetAdjustmentBehavior = .scrollableAxes
    title = "Home"

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem
      )
    }

    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Edit",
      style: .plain,
      target: self,
      action: #selector(editSectionsTapped)
    )
    configureCollectionView()
    configureDataSource()
    sharedHome.createFetchController()
    applySnapshot(animated: false)

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleThemeChanged),
      name: ThemeStore.didChangeNotification,
      object: nil
    )
  }

  @objc
  private func handleThemeChanged() {
    // PR 17.2: route through the shared helper so a gradient surface is
    // installed when the user has one enabled for the current mode, and
    // the solid background is restored otherwise.
    applyBackgroundSurface(to: collectionView)
    // reloadData refreshes cells AND supplementary views (section headers)
    collectionView.reloadData()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      applyBackgroundSurface(to: collectionView)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    sharedHome.updateFromRemote()
  }

  // MARK: - Layout

  private static func createLayout() -> UICollectionViewCompositionalLayout {
    let layout = UICollectionViewCompositionalLayout { sectionIndex, _ in
      guard let _ = HomeSection(rawValue: sectionIndex) else { return nil }

      // Item: square image with title below -> estimate height accommodates label
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      // Group: fixed width to show large image; height estimated to fit image + label
      // We'll use a vertical group containing the cell's content; the cell itself handles layout.
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .absolute(itemWidth),
        heightDimension: .estimated(210)
      )
      let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

      let sectionLayout = NSCollectionLayoutSection(group: group)
      sectionLayout.orthogonalScrollingBehavior = .continuous
      sectionLayout.interGroupSpacing = 12
      sectionLayout.contentInsets = NSDirectionalEdgeInsets(
        top: 8,
        leading: 16,
        bottom: 24,
        trailing: 16
      )

      // Header
      let headerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      )
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: headerSize,
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top
      )
      header.pinToVisibleBounds = false
      header.zIndex = 1
      sectionLayout.boundarySupplementaryItems = [header]

      return sectionLayout
    }
    return layout
  }

  // MARK: - CollectionView Setup

  private func configureCollectionView() {
    applyBackgroundSurface(to: collectionView)
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    collectionView.register(
      AuditionDeckHomeEntryCell.self,
      forCellWithReuseIdentifier: AuditionDeckHomeEntryCell.reuseID
    )
    collectionView.register(
      SectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: SectionHeaderView.reuseID
    )
  }

  // MARK: - Data Source

  private func configureDataSource() {
    dataSource = UICollectionViewDiffableDataSource<
      HomeSection,
      HomeCellItem
    >(collectionView: collectionView) { collectionView, indexPath, item in
      switch item {
      case let .content(homeItem):
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: AlbumCollectionCell.typeName,
          for: indexPath
        ) as! AlbumCollectionCell
        cell.display(
          container: homeItem.playableContainable,
          rootView: self,
          itemWidth: Self.itemWidth,
          initialIndexPath: indexPath
        )
        return cell

      case let .auxiliary(entry):
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: AuditionDeckHomeEntryCell.reuseID,
          for: indexPath
        ) as! AuditionDeckHomeEntryCell
        self.configureEntryCell(cell, kind: entry.kind, section: entry.section)
        return cell
      }
    }

    dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
      guard kind == UICollectionView.elementKindSectionHeader,
            let header = collectionView.dequeueReusableSupplementaryView(
              ofKind: kind,
              withReuseIdentifier: SectionHeaderView.reuseID,
              for: indexPath
            ) as? SectionHeaderView,
            let section = self.dataSource.snapshot().sectionIdentifiers
            .element(at: indexPath.section)
      else {
        return nil
      }
      header.title = section.title
      if section == .randomAlbums {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomAlbumsSection() }
      } else if section == .randomArtists {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomArtistsSection() }
      } else if section == .randomGenres {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomGenresSection() }
      } else if section == .randomSongs {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomSongsSection() }
      } else {
        header.showsRefreshButton = false
        header.setRefreshHandler(nil)
      }
      // Recent-tracks section header is tappable (entry point to the
      // synthetic detail view). For all other sections this is a no-op.
      if section == .recentTracks {
        header.setTapHandler { [weak self] in self?.pushRecentTracksDetail() }
      } else {
        header.setTapHandler(nil)
      }
      return header
    }
  }

  /// Sections that must be hidden from the Home snapshot when they have no
  /// items to show. Originally used to drop the standalone "Recently Added
  /// Tracks" header on fresh-install / empty-data states alongside the
  /// favourites sections (QA Bug B-2, 2026-04-11). `.recentTracks` was
  /// removed from this set per sprint Amp-1 (Director Review Round 1): once
  /// the widget is added to the home screen it must always render, even
  /// when `HomeManager.updateRecentTracks()` legitimately produces an empty
  /// (or short) result. `.favouriteAlbums` and `.favouritePlaylists` were
  /// removed from this set per sprint Discovery-D4: they now render the
  /// designed empty-section "Find more" card (§5.6) instead of hiding, see
  /// `sectionsWithFindMoreDoors` below. `.favouriteArtists` keeps the
  /// original B-2 hide-when-empty behaviour and remains opted in — there is
  /// no Discovery deck for artists, so it has no designed empty state to
  /// show instead.
  private static let sectionsHiddenWhenEmpty: Set<HomeSection> = [
    .favouriteArtists,
  ]

  /// Sections that get the full Discovery-D4 "Find more" door treatment
  /// (design §5.6/§2): a section-end trailing cell when populated, and an
  /// empty-section `ContentUnavailableView` card with a "Find more" button
  /// when empty. Both seed the deck from `.recentHistory` (design §2's
  /// entry table) and default to the matching candidate kind for the
  /// section (albums vs. playlists).
  private static let sectionsWithFindMoreDoors: Set<HomeSection> = [
    .favouriteAlbums, .favouritePlaylists,
  ]

  /// `.recentTracks` ("Recently Added Tracks") gets only the empty-section
  /// card, with no button and no trailing cell — design §2: "nothing to
  /// seed and Amperfy doesn't ingest." It was already exempt from
  /// `sectionsHiddenWhenEmpty` (see above), so before this sprint an empty
  /// library just showed a bare header with no cells; this adds the
  /// designed empty-state card in that gap.
  private static let sectionsWithNoButtonEmptyState: Set<HomeSection> = [.recentTracks]

  private func applySnapshot(animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeCellItem>()
    let visibleSections = sharedHome.orderedVisibleSections.filter { section in
      guard Self.sectionsHiddenWhenEmpty.contains(section) else { return true }
      return !(sharedHome.data[section]?.isEmpty ?? true)
    }
    snapshot.appendSections(visibleSections)
    for section in visibleSections {
      let items = sharedHome.data[section] ?? []
      let showsEmptyCard = items.isEmpty &&
        (
          Self.sectionsWithFindMoreDoors.contains(section) ||
            Self.sectionsWithNoButtonEmptyState.contains(section)
        )
      if showsEmptyCard {
        snapshot.appendItems(
          [.auxiliary(.init(kind: .emptySectionCard, section: section))],
          toSection: section
        )
      } else {
        snapshot.appendItems(items.map { HomeCellItem.content($0) }, toSection: section)
        if !items.isEmpty, Self.sectionsWithFindMoreDoors.contains(section) {
          snapshot.appendItems(
            [.auxiliary(.init(kind: .findMoreTrailingCell, section: section))],
            toSection: section
          )
        }
      }
    }
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  // Discovery-D4 "Find more" entry-point logic (cell configuration, per-
  // section copy, the empty-library guard, presenting the deck) lives in
  // `HomeVC+DiscoveryEntryPoints.swift`, following this codebase's existing
  // convention of splitting view-controller logic into `VC+Topic.swift`
  // extension files (e.g. `AlbumsCommonVCInteractions.swift`) rather than
  // growing a single already-large file further.

  @objc
  private func refreshOfflineMode() {
    os_log("HomeVC: OfflineModeChanged", log: self.log, type: .info)
    sharedHome.createFetchController()
  }

  @objc
  private func editSectionsTapped() {
    presentSectionEditor()
  }

  private func presentSectionEditor() {
    // Build a simple editor using a temporary UIViewController with a table view
    let editor = HomeEditorVC(current: sharedHome.orderedVisibleSections) { [weak self] newOrder in
      guard let self else { return }
      sharedHome.orderedVisibleSections = newOrder
      if let accountInfo = appDelegate.storage.settings.accounts.active {
        appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
          accountSettings.homeSections = newOrder
        }
      }
      applySnapshot(animated: true)

      sharedHome.createFetchController()
      sharedHome.updateFromRemote()
    }
    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .formSheet
    present(nav, animated: true)
  }

  @objc
  func refreshRandomAlbumsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomAlbums(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomArtistsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomArtists(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomGenresSection() {
    Task { @MainActor in
      await sharedHome.updateRandomGenres()
    }
  }

  @objc
  func refreshRandomSongsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomSongs(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  /// Push the synthetic playlist detail view backing the "Recently Added
  /// Tracks" widget. Reachable from both row taps and the section header
  /// (no horizontal-scroll footer slot exists for the "(X more in 7 days)"
  /// hint, so the header doubles as the entry point — see BACKLOG.md §3.2).
  func pushRecentTracksDetail() {
    let detail = RecentTracksDetailVC(account: account)
    navigationController?.pushViewController(detail, animated: true)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  // MARK: - Selection Handling

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    // Recent-tracks tiles route to the synthetic detail VC instead of an
    // entity detail screen — there is no parent album/artist/playlist for
    // a "recently added tracks" widget tile. See BACKLOG.md §3.2.
    if dataSource.snapshot().sectionIdentifiers.element(at: indexPath.section) == .recentTracks {
      pushRecentTracksDetail()
      return
    }

    guard let playableContainer = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return }

    if let album = playableContainer as? Album {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let artist = playableContainer as? Artist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let playlist = playableContainer as? Playlist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcastEpisode = playableContainer as? PodcastEpisode,
              let podcast = podcastEpisode.podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(
          account: account,
          podcast: podcast,
          episodeToScrollTo: podcastEpisode
        ),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcast = playableContainer as? Podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(account: account, podcast: podcast),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let _ = playableContainer as? Radio {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToRadios(account: account),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let genre = playableContainer as? Genre {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    }
  }
}

extension HomeVC {
  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let containable = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return nil }

    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      Task { @MainActor in
        do {
          try await containable.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error)
        }
        vc.refresh()
      }
      return vc
    }) { suggestedActions in
      var playIndexCB: (() -> PlayContext?)?
      playIndexCB = { PlayContext(containable: containable) }
      return EntityPreviewActionBuilder(
        container: containable,
        on: self,
        playContextCb: playIndexCB
      ).createMenu()
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    }
  }
}

// MARK: - SectionHeaderView

final class SectionHeaderView: UICollectionReusableView {
  static let reuseID = "SectionHeaderView"

  private let refreshButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(UIImage.refresh, for: .normal)
    btn.isHidden = true
    btn.accessibilityLabel = "Refresh Randoms"
    return btn
  }()

  private let titleLabel: UILabel = {
    let lbl = UILabel()
    lbl.translatesAutoresizingMaskIntoConstraints = false
    lbl.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
    lbl.textColor = .label
    return lbl
  }()

  var showsRefreshButton: Bool {
    get { !refreshButton.isHidden }
    set { refreshButton.isHidden = !newValue }
  }

  func setRefreshHandler(_ handler: (() -> ())?) {
    refreshButton.removeTarget(nil, action: nil, for: .allEvents)
    guard let handler else { return }
    refreshButton.addAction(UIAction { _ in handler() }, for: .touchUpInside)
  }

  private var tapHandler: (() -> ())?
  private var tapGestureRecognizer: UITapGestureRecognizer?

  /// Install a tap handler on the entire header view (currently used by the
  /// recent-tracks section to push the synthetic detail VC). Pass `nil` to
  /// remove an existing handler. Cells reuse, so we always either install a
  /// fresh recognizer or strip the previous one.
  func setTapHandler(_ handler: (() -> ())?) {
    if let existing = tapGestureRecognizer {
      removeGestureRecognizer(existing)
      tapGestureRecognizer = nil
    }
    tapHandler = handler
    isUserInteractionEnabled = true
    guard handler != nil else { return }
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleHeaderTap))
    addGestureRecognizer(recognizer)
    tapGestureRecognizer = recognizer
  }

  @objc
  private func handleHeaderTap() {
    tapHandler?()
  }

  var title: String? {
    didSet {
      titleLabel.text = title
      titleLabel.textColor = ThemeStore.shared.dynamicHeadingText ?? .label
      // PR 17.1: propagate the custom heading font (custom-font active loses
      // the `.semibold` weight trait; that is an accepted Release 1 trade-off
      // — see DESIGN_REVIEW_RELEASE_1.md Open Question 5).
      if ThemeStore.shared.isEnabled,
         ThemeStore.shared.fontFamily(for: UIScreen.main.traitCollection.userInterfaceStyle) != nil
      {
        titleLabel.font = UIFont.themed(style: .title3)
      } else {
        titleLabel.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(titleLabel)
    addSubview(refreshButton)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addSubview(titleLabel)
    addSubview(refreshButton)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    let descriptor = fontDescriptor.addingAttributes([
      UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}
