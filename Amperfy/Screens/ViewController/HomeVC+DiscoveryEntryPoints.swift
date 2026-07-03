//
//  HomeVC+DiscoveryEntryPoints.swift
//  Amperfy
//
//  Discovery-D4: Home widget "Find more" entry points (design doc
//  docs/ux/amperfy-needle-drop-deck-v1-design.md §5.6 / §2). Split out of
//  `HomeVC.swift` to keep that file's diff additive-and-small, following
//  this codebase's existing `VC+Topic.swift` extension convention.
//
//  D1a's sprint (docs/sprints/sprint-Discovery-D1a.md) specced this same
//  door, but nothing was ever actually built for it — the only trace left
//  behind was `HomeVC.sectionsHiddenWhenEmpty` hiding `.favouriteAlbums`/
//  `.favouritePlaylists` outright when empty. This file (plus the snapshot
//  changes in `HomeVC.swift` itself) is the real implementation.
//

import AmperfyKit
import CoreData
import UIKit

// MARK: - HomeCellItem

/// The Home collection view's diffable-data-source item type. Wraps the
/// pre-existing `HomeItem` (real library content, defined in
/// `HomeManager.swift` — deliberately left untouched by this sprint, see
/// report) for `.content`, and adds `.auxiliary` for the Discovery-D4
/// "Find more" entry-point cells (design §5.6/§2) laid on top of it.
///
/// Kept as a *separate* wrapper type rather than adding cases directly to
/// `HomeItem` because `HomeItem.playableContainable` is consumed
/// non-optionally elsewhere in the app (`Amperfy/CarPlay/
/// CarPlayHomeTabExtension.swift`, `CarPlaySceneDelegate.swift`) — making it
/// optional to accommodate a "no real content" auxiliary case would have
/// broken those call sites, which are out of this sprint's scope to touch.
enum HomeCellItem: Hashable {
  case content(HomeItem)
  case auxiliary(HomeAuxiliaryEntry)

  var playableContainable: PlayableContainable? {
    switch self {
    case let .content(item): item.playableContainable
    case .auxiliary: nil
    }
  }
}

// MARK: - HomeAuxiliaryEntryKind

enum HomeAuxiliaryEntryKind: Hashable {
  /// Section-end trailing cell shown after real content.
  case findMoreTrailingCell
  /// Whole-section replacement shown when a section has zero items.
  case emptySectionCard
}

// MARK: - HomeAuxiliaryEntry

/// A single auxiliary (non-content) Home cell. Carries its own identity
/// (`id`) so repeated `applySnapshot()` calls produce a fresh, distinct
/// diffable item each time — the same pattern `HomeItem` itself already
/// uses (`let id = UUID()`), so this doesn't introduce a new diffing
/// characteristic relative to the rest of the screen.
struct HomeAuxiliaryEntry: Hashable {
  let id = UUID()
  let kind: HomeAuxiliaryEntryKind
  let section: HomeSection

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension HomeVC {
  struct EntrySectionCopy {
    let title: String
    let description: String
    let systemImage: String
    let buttonTitle: String?
  }

  static func entrySectionCopy(for section: HomeSection) -> EntrySectionCopy {
    switch section {
    case .favouriteAlbums:
      EntrySectionCopy(
        title: "No favourite albums yet",
        description: "Audition some and tap the heart.",
        systemImage: "sparkle.magnifyingglass",
        buttonTitle: "Find more"
      )
    case .favouritePlaylists:
      EntrySectionCopy(
        title: "No favourite playlists yet",
        description: "Audition some and tap the heart.",
        systemImage: "sparkle.magnifyingglass",
        buttonTitle: "Find more"
      )
    case .recentTracks:
      EntrySectionCopy(
        title: "No tracks in your library yet",
        description: "Music you add will show up here.",
        systemImage: "music.note.list",
        buttonTitle: nil
      )
    default:
      // Not reached: only the sections above ever produce an
      // `.emptySectionCard`/`.findMoreTrailingCell` item — see
      // `sectionsWithFindMoreDoors`/`sectionsWithNoButtonEmptyState` in
      // `HomeVC.swift`.
      EntrySectionCopy(
        title: "",
        description: "",
        systemImage: "sparkle.magnifyingglass",
        buttonTitle: nil
      )
    }
  }

  func configureEntryCell(
    _ cell: AuditionDeckHomeEntryCell,
    kind: HomeAuxiliaryEntryKind,
    section: HomeSection
  ) {
    let isEnabled = hasListeningHistoryToSeedFrom
    switch kind {
    case .findMoreTrailingCell:
      cell.configureFindMore(isEnabled: isEnabled) { [weak self] in
        self?.presentAuditionDeck(seededFrom: section)
      }
    case .emptySectionCard:
      let copy = Self.entrySectionCopy(for: section)
      cell.configureEmptyState(
        title: copy.title,
        description: copy.description,
        systemImage: copy.systemImage,
        buttonTitle: copy.buttonTitle,
        isButtonEnabled: isEnabled,
        action: copy.buttonTitle != nil
          ? { [weak self] in self?.presentAuditionDeck(seededFrom: section) }
          : nil
      )
    }
  }

  /// Home widget "Find more" doors (design §2) always seed from listening
  /// history; the deck's default candidate kind matches the section so a
  /// tap from the playlists row deals playlists, not albums.
  ///
  /// Depends on `AuditionDeckHostVC(seed:defaultKind:)`, built in parallel
  /// by another agent in this sprint and not necessarily present yet — see
  /// sprint-Discovery-D4's brief. This call site is written against its
  /// documented signature.
  func presentAuditionDeck(seededFrom section: HomeSection) {
    let defaultKind: DeckCandidateKind = section == .favouritePlaylists ? .playlist : .album
    present(
      AuditionDeckHostVC(seed: .recentHistory, defaultKind: defaultKind),
      animated: true
    )
  }

  /// Empty-library guard (design §2): "if the library has no plays ... 'Find
  /// more' entry points render disabled." The Home doors always seed from
  /// `.recentHistory`, so plays are the actual signal that gates them — a
  /// single `fetchLimit = 1` existence query on `playCount > 0` is a cheap
  /// proxy for "do we have any listening history to seed from" without
  /// aggregating play counts across the whole library.
  var hasListeningHistoryToSeedFrom: Bool {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "%K > 0", #keyPath(SongMO.playCount))
    fetchRequest.fetchLimit = 1
    let matches = try? appDelegate.storage.main.context.fetch(fetchRequest)
    return matches?.isEmpty == false
  }
}
