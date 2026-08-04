//
//  NavidromeServerApi.swift
//  AmperfyKit
//
//  Created by Olivier on 20.05.26.
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

@preconcurrency import Alamofire
import Foundation
import os.log

// MARK: - NavidromeAuthResponse

public struct NavidromeAuthResponse: Codable, Sendable {
  public let token: String
}

// MARK: - NavidromeSortOrderUpdate

/// Tri-state for the `sortOrder` field of a partial folder update.
///
/// The contract distinguishes three cases that an `Int?` cannot express:
/// omitting the key leaves the stored value alone, a number sets it, and an
/// explicit JSON `null` clears it.
public enum NavidromeSortOrderUpdate: Sendable, Equatable {
  case unchanged
  case set(Int)
  case cleared
}

// MARK: - NavidromePlacementWrite

/// One entry of a replace-all placements body.
public struct NavidromePlacementWrite: Codable, Sendable, Equatable {
  /// Target folder. Accepts `""` or `"root"` for the root.
  public let folderId: String
  public let sortOrder: Int?

  public init(folderId: String, sortOrder: Int? = nil) {
    self.folderId = folderId
    self.sortOrder = sortOrder
  }
}

// MARK: - NavidromeApiError

public enum NavidromeApiError: Error, LocalizedError {
  case unauthorized
  case notFound
  case serverError(Int)
  case networkError(Error)
  case decodingError(Error)

  public var errorDescription: String? {
    switch self {
    case .unauthorized:
      return "Navidrome authentication failed"
    case .notFound:
      return "Requested resource not found"
    case let .serverError(statusCode):
      return "Navidrome server error (HTTP \(statusCode))"
    case let .networkError(underlyingError):
      return "Network error: \(underlyingError.localizedDescription)"
    case let .decodingError(underlyingError):
      return "Failed to decode response: \(underlyingError.localizedDescription)"
    }
  }
}

// MARK: - NavidromeServerApi

public final class NavidromeServerApi: Sendable {
  private let credentials: LoginCredentials
  private let jwtToken = Atomic<String?>(wrappedValue: nil)
  private let logger = Logger(subsystem: "dev.thisolivier.amperfy", category: "NavidromeApi")

  public init(credentials: LoginCredentials) {
    self.credentials = credentials
  }

  // MARK: - Authentication

  private func authenticate() async throws {
    let authUrl = credentials.serverUrl + "/auth/login"
    let authBody: [String: String] = [
      "username": credentials.username,
      "password": credentials.password,
    ]

    let serverUrl = credentials.serverUrl
    logger.info("Authenticating with Navidrome at \(serverUrl, privacy: .public)")

    do {
      let authResponse = try await AF.request(
        authUrl,
        method: .post,
        parameters: authBody,
        encoding: JSONEncoding.default
      )
      .validate()
      .serializingDecodable(NavidromeAuthResponse.self)
      .value

      jwtToken.wrappedValue = authResponse.token
      logger.info("Navidrome authentication successful")
    } catch {
      logger
        .error("Navidrome authentication failed: \(error.localizedDescription, privacy: .public)")
      throw NavidromeApiError.unauthorized
    }
  }

  private func authenticatedHeaders() async throws -> HTTPHeaders {
    if jwtToken.wrappedValue == nil {
      try await authenticate()
    }
    guard let token = jwtToken.wrappedValue else {
      throw NavidromeApiError.unauthorized
    }
    return HTTPHeaders(["Authorization": "Bearer \(token)"])
  }

  // MARK: - Generic Request Helpers

  private func request<ResponseType: Decodable>(
    _ responseType: ResponseType.Type,
    url: String,
    method: HTTPMethod = .get,
    parameters: Parameters? = nil,
    encoding: ParameterEncoding = URLEncoding.default
  ) async throws
    -> ResponseType {
    let headers = try await authenticatedHeaders()

    do {
      return try await AF.request(
        url,
        method: method,
        parameters: parameters,
        encoding: encoding,
        headers: headers
      )
      .validate()
      .serializingDecodable(ResponseType.self)
      .value
    } catch let afError as AFError {
      if case let .responseValidationFailed(reason) = afError,
         case let .unacceptableStatusCode(statusCode) = reason,
         statusCode == 401 {
        // Token expired — re-authenticate and retry once
        logger.info("JWT expired, re-authenticating")
        jwtToken.wrappedValue = nil
        let retryHeaders = try await authenticatedHeaders()
        do {
          return try await AF.request(
            url,
            method: method,
            parameters: parameters,
            encoding: encoding,
            headers: retryHeaders
          )
          .validate()
          .serializingDecodable(ResponseType.self)
          .value
        } catch let retryError as AFError {
          throw mapAFError(retryError)
        } catch let decodingError as DecodingError {
          throw NavidromeApiError.decodingError(decodingError)
        }
      }
      throw mapAFError(afError)
    } catch let decodingError as DecodingError {
      throw NavidromeApiError.decodingError(decodingError)
    } catch {
      throw NavidromeApiError.networkError(error)
    }
  }

  private func requestVoid(
    url: String,
    method: HTTPMethod,
    parameters: Parameters? = nil,
    encoding: ParameterEncoding = URLEncoding.default
  ) async throws {
    let headers = try await authenticatedHeaders()

    do {
      let _ = try await AF.request(
        url,
        method: method,
        parameters: parameters,
        encoding: encoding,
        headers: headers
      )
      .validate()
      .serializingData()
      .value
    } catch let afError as AFError {
      if case let .responseValidationFailed(reason) = afError,
         case let .unacceptableStatusCode(statusCode) = reason,
         statusCode == 401 {
        // Token expired — re-authenticate and retry once
        logger.info("JWT expired, re-authenticating")
        jwtToken.wrappedValue = nil
        let retryHeaders = try await authenticatedHeaders()
        do {
          let _ = try await AF.request(
            url,
            method: method,
            parameters: parameters,
            encoding: encoding,
            headers: retryHeaders
          )
          .validate()
          .serializingData()
          .value
          return
        } catch let retryError as AFError {
          throw mapAFError(retryError)
        }
      }
      throw mapAFError(afError)
    } catch {
      throw NavidromeApiError.networkError(error)
    }
  }

  private func mapAFError(_ afError: AFError) -> NavidromeApiError {
    if case let .responseValidationFailed(reason) = afError,
       case let .unacceptableStatusCode(statusCode) = reason {
      switch statusCode {
      case 401:
        return .unauthorized
      case 404:
        return .notFound
      default:
        return .serverError(statusCode)
      }
    }
    return .networkError(afError)
  }

  // MARK: - Base URL

  private var baseUrl: String {
    credentials.serverUrl
  }

  // MARK: - Folder CRUD (v2 organization contract)

  /// Probes whether this server owns playlist-folder data by fetching the v2
  /// organization envelope from `GET /api/playlist/folder`.
  ///
  /// Only a decodable envelope counts as proof. Stock Navidrome answers 404
  /// (`NavidromeApiError.notFound`) and the never-deployed v1 fork answered
  /// with a bare JSON array (`NavidromeApiError.decodingError`) — both are
  /// thrown here rather than silently treated as "the server has no folders",
  /// which is what made the destructive sync path reachable by accident.
  public func fetchFolderOrganization() async throws
    -> NavidromeFolderOrganizationResponse {
    let url = "\(baseUrl)/api/playlist/folder"
    logger.info("Probing playlist folder organization (v2 envelope)")
    return try await request(NavidromeFolderOrganizationResponse.self, url: url)
  }

  /// `POST /api/playlist/folder` with `{name, parentId?, sortOrder?}`.
  ///
  /// The v2 contract is camelCase throughout — the pre-v2 client sent
  /// `parent_id`, which this server ignores.
  public func createFolder(
    name: String,
    parentId: String?,
    sortOrder: Int? = nil
  ) async throws
    -> NavidromeOrganizationFolder {
    let url = "\(baseUrl)/api/playlist/folder"
    var bodyParameters: Parameters = ["name": name]
    if let parentId {
      bodyParameters["parentId"] = parentId
    }
    if let sortOrder {
      bodyParameters["sortOrder"] = sortOrder
    }
    logger.info("Creating playlist folder: \(name, privacy: .public)")
    return try await request(
      NavidromeOrganizationFolder.self,
      url: url,
      method: .post,
      parameters: bodyParameters,
      encoding: JSONEncoding.default
    )
  }

  /// `PUT /api/playlist/folder/{id}` with a partial body.
  ///
  /// Every field is independently optional: omitting a key leaves that property
  /// unchanged. `sortOrder` additionally distinguishes "leave alone" from
  /// "clear", the latter sent as an explicit JSON `null`, which is why it takes
  /// a tri-state rather than an `Int?`.
  ///
  /// The server answers 400 if `parentId` would create a cycle.
  public func updateFolder(
    id: String,
    name: String? = nil,
    parentId: String? = nil,
    sortOrder: NavidromeSortOrderUpdate = .unchanged
  ) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(id)"
    var bodyParameters: Parameters = [:]
    if let name {
      bodyParameters["name"] = name
    }
    if let parentId {
      bodyParameters["parentId"] = parentId
    }
    switch sortOrder {
    case .unchanged:
      break
    case let .set(newSortOrder):
      bodyParameters["sortOrder"] = newSortOrder
    case .cleared:
      bodyParameters["sortOrder"] = NSNull()
    }
    logger.info("Updating playlist folder: \(id, privacy: .public)")
    try await requestVoid(
      url: url,
      method: .put,
      parameters: bodyParameters,
      encoding: JSONEncoding.default
    )
  }

  /// `DELETE /api/playlist/folder/{id}`. The server re-parents the folder's
  /// children to its own parent and drops its placements; playlists survive.
  public func deleteFolder(id: String) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(id)"
    logger.info("Deleting playlist folder: \(id, privacy: .public)")
    try await requestVoid(url: url, method: .delete)
  }

  // MARK: - Placements

  /// Upsert one placement: `PUT /api/playlist/folder/{folderId}/playlist/{playlistId}`.
  ///
  /// `folderId` may be the literal `"root"` to file a playlist explicitly at the
  /// root, which is how a root placement gets an order (an *absent* placement
  /// also means root, but unordered).
  public func setPlaylistPlacement(
    folderId: String,
    playlistId: String,
    sortOrder: Int? = nil
  ) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(folderId)/playlist/\(playlistId)"
    var bodyParameters: Parameters = [:]
    if let sortOrder {
      bodyParameters["sortOrder"] = sortOrder
    }
    logger.info(
      "Placing playlist \(playlistId, privacy: .public) in folder \(folderId, privacy: .public)"
    )
    try await requestVoid(
      url: url,
      method: .put,
      parameters: bodyParameters.isEmpty ? nil : bodyParameters,
      encoding: JSONEncoding.default
    )
  }

  /// Remove one placement. Idempotent server-side.
  public func removePlaylistPlacement(folderId: String, playlistId: String) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(folderId)/playlist/\(playlistId)"
    logger.info(
      "Removing playlist \(playlistId, privacy: .public) from folder \(folderId, privacy: .public)"
    )
    try await requestVoid(url: url, method: .delete)
  }

  /// Replace every placement of one playlist in a single call:
  /// `PUT /api/playlist/{playlistId}/placements`.
  ///
  /// This is the move primitive — an empty `placements` array unfiles the
  /// playlist back to the implicit root.
  public func replacePlaylistPlacements(
    playlistId: String,
    placements: [NavidromePlacementWrite]
  ) async throws {
    let url = "\(baseUrl)/api/playlist/\(playlistId)/placements"
    let encodedPlacements: [[String: Any]] = placements.map { placement in
      var encoded: [String: Any] = ["folderId": placement.folderId]
      if let sortOrder = placement.sortOrder {
        encoded["sortOrder"] = sortOrder
      }
      return encoded
    }
    logger.info(
      """
      Replacing placements for playlist \(playlistId, privacy: .public) \
      (\(placements.count, privacy: .public) placement(s))
      """
    )
    try await requestVoid(
      url: url,
      method: .put,
      parameters: ["placements": encodedPlacements],
      encoding: JSONEncoding.default
    )
  }
}
