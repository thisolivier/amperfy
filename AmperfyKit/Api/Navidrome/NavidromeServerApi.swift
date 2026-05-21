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

// MARK: - NavidromeFolderResponse

public struct NavidromeFolderResponse: Codable, Sendable {
  public let id: String
  public let name: String
  public let parentId: String?

  enum CodingKeys: String, CodingKey {
    case id, name
    case parentId = "parent_id"
  }
}

// MARK: - NavidromeFolderDetailResponse

public struct NavidromeFolderDetailResponse: Codable, Sendable {
  public let id: String
  public let name: String
  public let parentId: String?
  public let childFolders: [NavidromeFolderResponse]?
  public let playlists: [NavidromePlaylistRef]?

  enum CodingKeys: String, CodingKey {
    case id, name, playlists
    case parentId = "parent_id"
    case childFolders = "child_folders"
  }
}

// MARK: - NavidromePlaylistRef

public struct NavidromePlaylistRef: Codable, Sendable {
  public let id: String
  public let name: String
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

  // MARK: - Folder CRUD

  public func listFolders() async throws -> [NavidromeFolderResponse] {
    let url = "\(baseUrl)/api/playlist/folder"
    logger.info("Listing playlist folders")
    return try await request([NavidromeFolderResponse].self, url: url)
  }

  public func getFolder(id: String) async throws -> NavidromeFolderDetailResponse {
    let url = "\(baseUrl)/api/playlist/folder/\(id)"
    logger.info("Getting playlist folder: \(id, privacy: .public)")
    return try await request(NavidromeFolderDetailResponse.self, url: url)
  }

  public func createFolder(name: String, parentId: String?) async throws
    -> NavidromeFolderResponse {
    let url = "\(baseUrl)/api/playlist/folder"
    var bodyParameters: [String: String] = ["name": name]
    if let parentId = parentId {
      bodyParameters["parent_id"] = parentId
    }
    logger.info("Creating playlist folder: \(name, privacy: .public)")
    return try await request(
      NavidromeFolderResponse.self,
      url: url,
      method: .post,
      parameters: bodyParameters,
      encoding: JSONEncoding.default
    )
  }

  public func updateFolder(id: String, name: String?, parentId: String?) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(id)"
    var bodyParameters: [String: String] = [:]
    if let name = name {
      bodyParameters["name"] = name
    }
    if let parentId = parentId {
      bodyParameters["parent_id"] = parentId
    }
    logger.info("Updating playlist folder: \(id, privacy: .public)")
    try await requestVoid(
      url: url,
      method: .put,
      parameters: bodyParameters,
      encoding: JSONEncoding.default
    )
  }

  public func deleteFolder(id: String) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(id)"
    logger.info("Deleting playlist folder: \(id, privacy: .public)")
    try await requestVoid(url: url, method: .delete)
  }

  // MARK: - Folder Membership

  public func addPlaylistToFolder(folderId: String, playlistId: String) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(folderId)/playlist/\(playlistId)"
    logger.info(
      "Adding playlist \(playlistId, privacy: .public) to folder \(folderId, privacy: .public)"
    )
    try await requestVoid(url: url, method: .post)
  }

  public func removePlaylistFromFolder(folderId: String, playlistId: String) async throws {
    let url = "\(baseUrl)/api/playlist/folder/\(folderId)/playlist/\(playlistId)"
    logger.info(
      "Removing playlist \(playlistId, privacy: .public) from folder \(folderId, privacy: .public)"
    )
    try await requestVoid(url: url, method: .delete)
  }
}
