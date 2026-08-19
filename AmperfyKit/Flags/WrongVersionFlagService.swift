//
//  WrongVersionFlagService.swift
//  AmperfyKit
//
//  Fire-and-forget client for the "wrong version" flags feature
//  (docs/WRONG_VERSION_FLAGS_SPEC.md, Build 1). The user taps the flag button
//  on the full-screen player, optionally types a note, and this posts one row
//  to soulseek-navi-server; NaviAdmin triages the list later. Amperfy never
//  reads flag state back, so there is no cache and no local model.
//
//  Routing mirrors GigsService: the shared AdjacencyGatewaySettings gateway
//  (URL + X-API-Key) with the `/navi` path prefix, i.e.
//  `{gateway}/navi/api/v1/flags`. Unlike adjacency/gigs there is NO legacy
//  direct-to-host fallback — soulseek-navi-server is only ever reachable
//  through the gateway — so an unconfigured gateway is a distinct
//  `.notConfigured` failure the caller surfaces as an actionable banner.
//
//  This is the codebase's first POST over plain URLSession: `httpMethod`,
//  `Content-Type: application/json` and a JSONEncoder-encoded body. Optional
//  payload fields are OMITTED (not null) when nil — Swift's synthesized
//  encoding uses `encodeIfPresent` — which is what the server's pydantic model
//  expects.
//
//  Build 1 deliberately has NO retry queue: a failed flag is reported to the
//  user and dropped. If that proves annoying in real use, the fix is a small
//  persisted outbox, not a retry loop inside this call.
//
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

// MARK: - WrongVersionFlagPayload

/// The POST body, camelCase, exactly matching the server's pydantic model
/// (spec "API contract (Build 1)"). Only `songId` is required; every other
/// field is omitted from the JSON when nil.
public struct WrongVersionFlagPayload: Codable, Equatable, Sendable {
  public let songId: String
  public let title: String?
  public let artist: String?
  public let album: String?
  public let note: String?
  public let contextName: String?
  public let appVersion: String?
  public let buildNumber: String?

  public init(
    songId: String,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    note: String? = nil,
    contextName: String? = nil,
    appVersion: String? = WrongVersionFlagService.bundleAppVersion(),
    buildNumber: String? = WrongVersionFlagService.bundleBuildNumber()
  ) {
    self.songId = songId
    self.title = title
    self.artist = artist
    self.album = album
    self.note = note
    self.contextName = contextName
    self.appVersion = appVersion
    self.buildNumber = buildNumber
  }
}

// MARK: - WrongVersionFlagError

public enum WrongVersionFlagError: Error, Equatable {
  /// No gateway URL + key configured — the flag cannot be sent anywhere.
  case notConfigured
  /// Transport-level failure (offline, gateway down, timeout).
  case unreachable
  /// The gateway/server answered with a non-2xx status.
  case badResponse(statusCode: Int)
  /// The payload could not be encoded (should never happen in practice).
  case encodingFailed
}

// MARK: LocalizedError

extension WrongVersionFlagError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Gateway not configured — set the Gateway URL and Key in Settings > Discovery."
    case .unreachable:
      return "Could not reach the server. The flag was not saved."
    case let .badResponse(statusCode):
      return "Server rejected the flag (HTTP \(statusCode))."
    case .encodingFailed:
      return "Could not encode the flag request."
    }
  }
}

// MARK: - WrongVersionFlagService

public final class WrongVersionFlagService: @unchecked Sendable {
  /// The gateway routes `/navi/*` to soulseek-navi-server.
  public static let gatewaySidecarPathPrefix = "/navi"
  /// The server's own flags path (router prefix `/flags` under `/api/v1`).
  public static let flagsPath = "/api/v1/flags"
  public static let contentTypeHeaderName = "Content-Type"
  public static let jsonContentType = "application/json"

  private let gatewaySettings: AdjacencyGatewaySettings
  private let session: URLSession

  public init(
    gatewaySettings: AdjacencyGatewaySettings = .shared,
    session: URLSession = DiscoveryURLSession.fastFail
  ) {
    self.gatewaySettings = gatewaySettings
    self.session = session
  }

  /// True when a gateway route exists — the caller can pre-check before
  /// presenting the flag dialog if it wants to.
  public var isConfigured: Bool {
    gatewaySettings.activeRoute != nil
  }

  /// POST one flag. Fire-and-forget: returns normally on 2xx, throws a typed
  /// `WrongVersionFlagError` otherwise. Nothing is retried or queued.
  public func submitFlag(_ payload: WrongVersionFlagPayload) async throws {
    guard let route = gatewaySettings.activeRoute,
          let requestURL = Self.gatewayURL(route: route)
    else { throw WrongVersionFlagError.notConfigured }

    let body: Data
    do {
      body = try Self.encode(payload: payload)
    } catch {
      throw WrongVersionFlagError.encodingFailed
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.setValue(route.apiKey, forHTTPHeaderField: AdjacencyGatewayRoute.apiKeyHeaderName)
    request.setValue(Self.jsonContentType, forHTTPHeaderField: Self.contentTypeHeaderName)
    request.httpBody = body

    let response: URLResponse
    do {
      (_, response) = try await session.data(for: request)
    } catch {
      throw WrongVersionFlagError.unreachable
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw WrongVersionFlagError.unreachable
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw WrongVersionFlagError.badResponse(statusCode: httpResponse.statusCode)
    }
  }

  // MARK: - Encoding / URL building (shared with unit tests)

  /// JSON body for a payload. Optional fields that are nil are omitted.
  public static func encode(payload: WrongVersionFlagPayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(payload)
  }

  /// `{gatewayURL}/navi/api/v1/flags` — the same rebasing shape as
  /// `AdjacencyGatewayRoute.url(sidecarPath:)`, but with the `/navi` prefix.
  public static func gatewayURL(route: AdjacencyGatewayRoute) -> URL? {
    guard var components = URLComponents(url: route.baseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    let basePath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = basePath + gatewaySidecarPathPrefix + flagsPath
    return components.url
  }

  // MARK: - Bundle metadata

  /// `CFBundleShortVersionString` (e.g. "1.9.2"), nil when unavailable.
  public static func bundleAppVersion(_ bundle: Bundle = .main) -> String? {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  /// `CFBundleVersion` (the build number, e.g. "85"), nil when unavailable.
  public static func bundleBuildNumber(_ bundle: Bundle = .main) -> String? {
    bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }
}
