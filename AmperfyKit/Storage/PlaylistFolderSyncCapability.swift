//
//  PlaylistFolderSyncCapability.swift
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

import Foundation

// MARK: - NavidromeOrganizationFolder

/// A folder entry inside the v2 playlist-folder organization envelope.
///
/// Also the response type of folder create, so a folder round-trips through the
/// same shape it syncs in. The v2 contract is camelCase throughout (`parentId`);
/// the removed pre-v2 endpoints used snake_case (`parent_id`), which is why a
/// client written against them silently failed to send a parent at all.
public struct NavidromeOrganizationFolder: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let parentId: String?
  public let sortOrder: Int?

  public init(id: String, name: String, parentId: String?, sortOrder: Int? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
    self.sortOrder = sortOrder
  }

  /// `parentId` normalized for storage: the server spells "at the root" as an
  /// empty string, local Core Data spells it as `nil`.
  public var normalizedParentId: String? {
    guard let parentId = parentId, !parentId.isEmpty else { return nil }
    return parentId
  }
}

// MARK: - NavidromeOrganizationPlacement

/// A playlist placement inside the v2 organization envelope.
///
/// Decoded so the capability probe can tell an empty server organization from a
/// populated one. Placements are deliberately *not* consumed for membership or
/// ordering yet — that is a follow-up change.
public struct NavidromeOrganizationPlacement: Codable, Sendable, Equatable {
  public let playlistId: String
  public let folderId: String?
  public let sortOrder: Int?

  public init(playlistId: String, folderId: String?, sortOrder: Int? = nil) {
    self.playlistId = playlistId
    self.folderId = folderId
    self.sortOrder = sortOrder
  }
}

// MARK: - NavidromeFolderOrganizationResponse

/// The v2 response envelope of `GET /api/playlist/folder`.
///
/// Decoding this successfully — with `folderApiVersion` at or above
/// ``minimumSupportedFolderApiVersion`` — is the *only* accepted proof that the
/// server owns playlist-folder data. Stock Navidrome has no such endpoint (404)
/// and the never-deployed v1 fork answered with a bare JSON array; both fail to
/// decode here, which is exactly the intent.
public struct NavidromeFolderOrganizationResponse: Codable, Sendable, Equatable {
  /// Destructive reconciliation requires at least this `folderApiVersion`.
  public static let minimumSupportedFolderApiVersion = 2

  public let folderApiVersion: Int
  public let folders: [NavidromeOrganizationFolder]
  public let placements: [NavidromeOrganizationPlacement]

  public init(
    folderApiVersion: Int,
    folders: [NavidromeOrganizationFolder] = [],
    placements: [NavidromeOrganizationPlacement] = []
  ) {
    self.folderApiVersion = folderApiVersion
    self.folders = folders
    self.placements = placements
  }

  enum CodingKeys: String, CodingKey {
    case folderApiVersion, folders, placements
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `folderApiVersion` is required — its absence is what distinguishes a
    // non-envelope 200 body from a genuine folder-owning server.
    self.folderApiVersion = try container.decode(Int.self, forKey: .folderApiVersion)
    self.folders = try container.decodeIfPresent(
      [NavidromeOrganizationFolder].self, forKey: .folders
    ) ?? []
    self.placements = try container.decodeIfPresent(
      [NavidromeOrganizationPlacement].self, forKey: .placements
    ) ?? []
  }

  /// True when the server reports no folders *and* no placements at all. This
  /// is the exact shape of the 2026-08-02 data loss, where a corrupted server
  /// answered "I have nothing" and the client obediently deleted everything.
  public var isEmptyOrganization: Bool {
    folders.isEmpty && placements.isEmpty
  }
}

// MARK: - PlaylistFolderServerUnsupportedReason

/// Why the server failed to prove it owns playlist-folder data.
public enum PlaylistFolderServerUnsupportedReason: Equatable, Sendable {
  /// Stock Navidrome: the folder endpoint does not exist.
  case endpointNotFound
  /// Any other transport or server failure.
  case requestFailed(description: String)
  /// HTTP 200, but the body is not a v2 organization envelope — including the
  /// old, never-deployed bare-array shape.
  case responseNotAnOrganizationEnvelope
  /// A well-formed envelope that predates the contract we can safely act on.
  case folderApiVersionTooOld(reportedVersion: Int)

  public var logDescription: String {
    switch self {
    case .endpointNotFound:
      return "folder endpoint returned 404 (stock Navidrome, no folder API)"
    case let .requestFailed(description):
      return "folder request failed: \(description)"
    case .responseNotAnOrganizationEnvelope:
      return "response body was not a v2 folder organization envelope"
    case let .folderApiVersionTooOld(reportedVersion):
      let minimumVersion = NavidromeFolderOrganizationResponse
        .minimumSupportedFolderApiVersion
      return "server reported folderApiVersion \(reportedVersion), "
        + "minimum required is \(minimumVersion)"
    }
  }
}

// MARK: - PlaylistFolderSyncDecision

/// What `PlaylistFolderStore.syncFromServer()` is permitted to do this pass.
public enum PlaylistFolderSyncDecision: Sendable {
  /// The server proved it owns folder data — destructive reconciliation is
  /// permitted using the supplied organization.
  case reconcile(organization: NavidromeFolderOrganizationResponse)
  /// The server did not prove folder ownership — local state must be left
  /// exactly as it is.
  case skipServerLacksFolderApi(reason: PlaylistFolderServerUnsupportedReason)
  /// The server owns folder data but reported an empty organization while the
  /// device still holds folders. Reconciling would mass-delete them.
  case skipEmptyServerOrganizationWouldWipeLocalFolders(localFolderCount: Int)
}

// MARK: - PlaylistFolderSyncCapability

/// Pure decision layer for playlist-folder sync.
///
/// Kept free of Core Data and networking so the safety rules — the ones whose
/// absence cost the owner their entire folder structure on 2026-08-02 — can be
/// tested directly.
public enum PlaylistFolderSyncCapability {
  /// Decide whether destructive reconciliation may run.
  ///
  /// - Parameters:
  ///   - probeOutcome: Result of fetching the v2 organization envelope.
  ///   - localFolderCount: Number of folders currently stored on the device.
  public static func evaluate(
    probeOutcome: Result<NavidromeFolderOrganizationResponse, Error>,
    localFolderCount: Int
  )
    -> PlaylistFolderSyncDecision {
    switch probeOutcome {
    case let .failure(probeError):
      return .skipServerLacksFolderApi(reason: unsupportedReason(for: probeError))

    case let .success(organization):
      let minimumVersion = NavidromeFolderOrganizationResponse
        .minimumSupportedFolderApiVersion
      guard organization.folderApiVersion >= minimumVersion else {
        return .skipServerLacksFolderApi(
          reason: .folderApiVersionTooOld(reportedVersion: organization.folderApiVersion)
        )
      }
      // Belt: even a confirmed folder-owning server does not get to empty the
      // device in one pass.
      if organization.isEmptyOrganization, localFolderCount > 0 {
        return .skipEmptyServerOrganizationWouldWipeLocalFolders(
          localFolderCount: localFolderCount
        )
      }
      return .reconcile(organization: organization)
    }
  }

  /// Classify a probe failure. Every classification is non-destructive; the
  /// distinction exists only so the warning log says something useful.
  public static func unsupportedReason(for probeError: Error)
    -> PlaylistFolderServerUnsupportedReason {
    if let navidromeError = probeError as? NavidromeApiError {
      switch navidromeError {
      case .notFound:
        return .endpointNotFound
      case .decodingError:
        return .responseNotAnOrganizationEnvelope
      case .unauthorized:
        return .requestFailed(description: "unauthorized")
      case let .serverError(statusCode):
        return .requestFailed(description: "HTTP \(statusCode)")
      case let .networkError(underlyingError):
        return .requestFailed(description: underlyingError.localizedDescription)
      }
    }
    if probeError is DecodingError {
      return .responseNotAnOrganizationEnvelope
    }
    return .requestFailed(description: probeError.localizedDescription)
  }
}
