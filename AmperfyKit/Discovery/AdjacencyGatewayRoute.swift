//
//  AdjacencyGatewayRoute.swift
//  AmperfyKit
//
//  The single shared helper for gateway-vs-direct routing of adjacency
//  requests. When AdjacencyGatewaySettings has BOTH a gateway URL and an API
//  key, `AdjacencyGatewaySettings.activeRoute` returns one of these and the
//  three call sites (AdjacencySidecarClient, DeckSpriteManifestFetcher,
//  sprite-audio AVURLAsset) build `{gatewayURL}/adjacency{sidecarPath}` and
//  attach `X-API-Key`. When it returns nil, every call site keeps its legacy
//  Navidrome-host:sidecar-port derivation byte-for-byte unchanged.
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

// MARK: - AdjacencyRequestMode

/// Which path an adjacency request took — recorded into DiscoveryTelemetry
/// and shown on the Discovery Diagnostics screen.
public enum AdjacencyRequestMode: String, Sendable {
  case gateway
  case direct
}

// MARK: - AdjacencyGatewayRoute

/// A validated, active gateway destination: base URL + API key.
public struct AdjacencyGatewayRoute: Sendable {
  public static let apiKeyHeaderName = "X-API-Key"
  /// The gateway routes `/adjacency/*` to the adjacency-sidecar.
  public static let sidecarPathPrefix = "/adjacency"

  public let baseURL: URL
  public let apiKey: String

  /// Nil unless both values are non-empty (after trimming) and the URL is a
  /// usable absolute URL — the "BOTH set" rule for gateway mode.
  public static func make(urlString: String, apiKey: String) -> AdjacencyGatewayRoute? {
    let trimmedUrlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUrlString.isEmpty, !trimmedApiKey.isEmpty,
          let gatewayURL = URL(string: trimmedUrlString), gatewayURL.host != nil
    else { return nil }
    return AdjacencyGatewayRoute(baseURL: gatewayURL, apiKey: trimmedApiKey)
  }

  /// The `X-API-Key` header as a ready-to-merge dictionary (URLRequest and
  /// AVURLAsset option shapes alike).
  public var httpHeaderFields: [String: String] {
    [Self.apiKeyHeaderName: apiKey]
  }

  /// `{gatewayURL}/adjacency{sidecarPath}` plus optional query items.
  /// `sidecarPath` is the sidecar's own path (e.g. `/similar-collections`).
  public func url(sidecarPath: String, queryItems: [URLQueryItem]? = nil) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    let basePath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = basePath + Self.sidecarPathPrefix + sidecarPath
    if let queryItems, !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    return components.url
  }

  /// Rebases an existing sidecar URL — absolute, or server-relative like the
  /// sprite manifest's `/sprite-audio?...` — through the gateway, keeping its
  /// path and query: `/sprite-audio?a=1` -> `{gatewayURL}/adjacency/sprite-audio?a=1`.
  public func url(rebasing sidecarURL: URL) -> URL? {
    let sidecarComponents = URLComponents(url: sidecarURL, resolvingAgainstBaseURL: false)
    let sidecarPath = sidecarComponents?.path ?? sidecarURL.path
    guard let rebasedURL = url(sidecarPath: sidecarPath),
          var rebasedComponents = URLComponents(url: rebasedURL, resolvingAgainstBaseURL: false)
    else { return nil }
    rebasedComponents.percentEncodedQuery = sidecarComponents?.percentEncodedQuery
    return rebasedComponents.url
  }
}

// MARK: - AdjacencyConnectionTest

/// Result wording for the Discovery Diagnostics "Test Sidecar Connection"
/// button — pulled out of the view so the 401-classification is unit-testable.
public enum AdjacencyConnectionTest {
  /// A 401 in gateway mode is the gateway rejecting the static key — a
  /// distinct, actionable failure, not a generic connection problem.
  public static func resultText(
    urlString: String,
    statusCode: Int,
    latencyMilliseconds: Int,
    mode: AdjacencyRequestMode
  )
    -> String {
    if mode == .gateway, statusCode == 401 {
      return "URL: \(urlString)\nMode: gateway\n" +
        "HTTP 401 — gateway key rejected. Check the Gateway Key in Settings."
    }
    return "URL: \(urlString)\nMode: \(mode.rawValue)\n" +
      "HTTP \(statusCode)\nLatency: \(latencyMilliseconds) ms"
  }
}
