//
//  PlaylistFolderStore+Sync.swift
//  AmperfyKit
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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

import CoreData
import Foundation

extension PlaylistFolderStore {
  // MARK: - Sync (called during library sync)

  /// Sync folders and placements from server to CoreData. Called during the
  /// library sync flow.
  ///
  /// Destructive reconciliation — deleting local folders or placements because
  /// the server did not mention them — runs **only** behind a capability probe.
  /// The server must answer `GET /api/playlist/folder` with a v2 organization
  /// envelope (`folderApiVersion >= 2`). A 404, any other failure, or a 200 that
  /// is not an envelope all mean "this server does not own folder data", and
  /// local state is left completely untouched.
  ///
  /// Background: this fork shipped against a Navidrome folder API that was never
  /// deployed. Every folder call 404'd, protected only by `try?` swallowing the
  /// error. On 2026-08-02 a resync against a corrupted server took the "success"
  /// branch and delete-if-absent reconciliation wiped the entire folder tree.
  public func syncFromServer() async throws {
    guard let context = managedObjectContext,
          let organizationFetcher = folderOrganizationFetcher else { return }

    let probeOutcome: Result<NavidromeFolderOrganizationResponse, Error>
    do {
      probeOutcome = .success(try await organizationFetcher())
    } catch {
      probeOutcome = .failure(error)
    }

    let localFolderCount = await MainActor.run {
      ((try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []).count
    }

    let syncDecision = PlaylistFolderSyncCapability.evaluate(
      probeOutcome: probeOutcome,
      localFolderCount: localFolderCount
    )

    switch syncDecision {
    case let .skipServerLacksFolderApi(reason):
      logServerLacksFolderApiOnce(reason: reason)

    case let .skipEmptyServerOrganizationWouldWipeLocalFolders(localFolderCount):
      logger.warning(
        """
        Playlist folder sync skipped: server confirmed folder support but \
        reported an empty organization while \(localFolderCount, privacy: .public) \
        local folder(s) exist. Refusing to mass-delete; local folders kept.
        """
      )

    case let .reconcile(organization):
      await reconcile(organization: organization, in: context)
      notifyChange()
      await MainActor.run { self.exportCurrentTree() }
    }
  }

  /// Apply a capability-confirmed server organization to Core Data.
  ///
  /// Only reached once ``PlaylistFolderSyncCapability`` has authorized
  /// destructive reconciliation.
  ///
  /// Both folders *and* playlist placements come from the one envelope. The
  /// pre-v2 path refilled memberships from a per-folder detail loop, which meant
  /// a folder whose detail request failed was emptied rather than skipped —
  /// residual vector for exactly the class of loss the capability gate exists to
  /// prevent. There is no second request here to fail.
  func reconcile(
    organization: NavidromeFolderOrganizationResponse,
    in context: NSManagedObjectContext
  ) async {
    await MainActor.run {
      self.reconcileFolders(organization: organization, in: context)
      self.reconcilePlacements(organization: organization, in: context)
      try? context.save()
    }
  }

  private func reconcileFolders(
    organization: NavidromeFolderOrganizationResponse,
    in context: NSManagedObjectContext
  ) {
    let existingFolderMOs = (try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []
    var existingFolderMOsById = [String: PlaylistFolderMO]()
    for folderMO in existingFolderMOs {
      existingFolderMOsById[folderMO.id] = folderMO
    }

    var serverFolderIds = Set<String>()
    for serverFolder in organization.folders {
      serverFolderIds.insert(serverFolder.id)
      let folderMO = existingFolderMOsById[serverFolder.id]
        ?? PlaylistFolderMO(context: context)
      folderMO.id = serverFolder.id
      folderMO.name = serverFolder.name
      folderMO.parentId = serverFolder.normalizedParentId
      folderMO.sortOrderValue = serverFolder.sortOrder
      if folderMO.account == nil {
        folderMO.account = accountMO
      }
    }

    // Delete folders the server no longer has. Deleting a folder cascades to its
    // placements but — by the v52 delete rules — never reaches a playlist.
    for existingFolderMO in existingFolderMOs
      where !serverFolderIds.contains(existingFolderMO.id) {
      for placementMO in fetchPlacements(folderId: existingFolderMO.id, in: context) {
        context.delete(placementMO)
      }
      context.delete(existingFolderMO)
    }
    try? context.save()
  }

  private func reconcilePlacements(
    organization: NavidromeFolderOrganizationResponse,
    in context: NSManagedObjectContext
  ) {
    let localPlaylistMOs = (try? context.fetch(PlaylistMO.fetchRequest())) ?? []
    var playlistMOsById = [String: PlaylistMO]()
    for playlistMO in localPlaylistMOs {
      playlistMOsById[playlistMO.id] = playlistMO
    }

    let resolution = PlaylistFolderPlacementReconciler.resolve(
      organization: organization,
      knownPlaylistIds: Set(playlistMOsById.keys)
    )
    logSkippedPlacements(resolution)

    var existingPlacementMOsByEdge = [String: PlaylistFolderPlacementMO]()
    for placementMO in fetchPlacements(in: context) {
      guard let playlistId = placementMO.playlist?.id else {
        // An edge with no playlist cannot mean anything; drop it.
        context.delete(placementMO)
        continue
      }
      existingPlacementMOsByEdge[Self.edgeKey(
        playlistId: playlistId, folderId: placementMO.folderId
      )] = placementMO
    }

    var serverEdgeKeys = Set<String>()
    for placement in resolution.resolvedPlacements {
      let edgeKey = Self.edgeKey(
        playlistId: placement.playlistId, folderId: placement.folderId
      )
      serverEdgeKeys.insert(edgeKey)

      let placementMO: PlaylistFolderPlacementMO
      if let existingPlacementMO = existingPlacementMOsByEdge[edgeKey] {
        placementMO = existingPlacementMO
      } else {
        guard let playlistMO = playlistMOsById[placement.playlistId] else { continue }
        placementMO = makePlacementMO(
          playlist: playlistMO, folderId: placement.folderId, in: context
        )
      }
      placementMO.sortOrderValue = placement.sortOrder
      if placementMO.account == nil {
        placementMO.account = accountMO
      }
    }

    // Drop edges the server no longer has. A folder named by no placement is an
    // *empty folder*, not a missing one — it was reconciled above from
    // `folders` and survives untouched here.
    for (edgeKey, placementMO) in existingPlacementMOsByEdge
      where !serverEdgeKeys.contains(edgeKey) {
      context.delete(placementMO)
    }
  }

  private static func edgeKey(playlistId: String, folderId: String) -> String {
    "\(playlistId)\u{1F}\(PlaylistFolderRootId.normalized(folderId))"
  }

  private func logSkippedPlacements(_ resolution: PlaylistFolderPlacementResolution) {
    if !resolution.skippedUnknownPlaylistIds.isEmpty {
      logger.info(
        """
        Playlist folder sync skipped \
        \(resolution.skippedUnknownPlaylistIds.count, privacy: .public) placement(s) \
        naming playlists this device does not have. Local playlists are never \
        fabricated from folder data.
        """
      )
    }
    if !resolution.skippedUnknownFolderIds.isEmpty {
      logger.warning(
        """
        Playlist folder sync skipped placements into \
        \(resolution.skippedUnknownFolderIds.count, privacy: .public) folder(s) the \
        same envelope did not declare.
        """
      )
    }
  }

  func logServerLacksFolderApiOnce(reason: PlaylistFolderServerUnsupportedReason) {
    guard !hasLoggedServerLacksFolderApi else { return }
    hasLoggedServerLacksFolderApi = true
    logger.warning(
      """
      Playlist folder sync skipped: server did not confirm folder API v2 \
      support (\(reason.logDescription, privacy: .public)). Local folders and \
      memberships left untouched.
      """
    )
  }

  // MARK: - Legacy membership backfill

  /// One-time carry-over of pre-v2 memberships into placements.
  ///
  /// Before v52 memberships lived in a bare many-to-many join with nowhere to
  /// record order. That relationship is deliberately still in the model so this
  /// backfill has something to read: dropping it in the migration would have
  /// been schema-clean and would have silently thrown away every existing
  /// device's folder organization.
  ///
  /// Runs only when placements are empty and legacy edges exist, so it cannot
  /// resurrect memberships a user has since deleted.
  func backfillPlacementsFromLegacyMembershipsIfNeeded(in context: NSManagedObjectContext) {
    guard fetchPlacements(in: context).isEmpty else { return }

    let folderMOs = (try? context.fetch(PlaylistFolderMO.fetchRequest())) ?? []
    var backfilledPlacementCount = 0

    for folderMO in folderMOs {
      guard let legacyPlaylistMOs = folderMO.playlists as? Set<PlaylistMO>,
            !legacyPlaylistMOs.isEmpty else { continue }
      // Give the carried-over edges a stable starting order: name order, which
      // is what the pre-v2 UI displayed anyway.
      let orderedPlaylistMOs = legacyPlaylistMOs.sorted {
        ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
      }
      var nextSortOrder = PlaylistFolderOrdering.sortOrderGap
      for playlistMO in orderedPlaylistMOs {
        guard fetchPlacement(
          playlistId: playlistMO.id, folderId: folderMO.id, in: context
        ) == nil else { continue }
        let placementMO = makePlacementMO(
          playlist: playlistMO, folderId: folderMO.id, in: context
        )
        placementMO.sortOrderValue = nextSortOrder
        nextSortOrder += PlaylistFolderOrdering.sortOrderGap
        backfilledPlacementCount += 1
      }
    }

    guard backfilledPlacementCount > 0 else { return }
    try? context.save()
    logger.info(
      """
      Carried \(backfilledPlacementCount, privacy: .public) pre-v2 playlist folder \
      membership(s) over to placements.
      """
    )
    exportCurrentTree()
  }
}
