//
//  GigsService.swift
//  AmperfyKit
//
//  HTTP client for the gigs-sidecar (spec §1.2 endpoints, frozen event JSON).
//  Plain URLSession + Codable, no Alamofire — same minimal-dependency choice as
//  AdjacencySidecarClient. Routing mirrors the adjacency pattern: when the
//  shared AdjacencyGatewaySettings holds BOTH a URL and key, requests go to
//  `{gateway}/gigs/api/gigs/events` with `X-API-Key`; otherwise the legacy
//  `{server host}:{gigs port}/api/gigs/events` derivation applies.
//
//  Caching: every successful fetch is stored per-scope in GigsSettings, and the
//  view falls back to that cache (with an "as of" timestamp) when the sidecar
//  is unreachable.
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
import OSLog

// MARK: - GigScope

/// What the Gigs view is asking for. Each scope has a stable cache key so the
/// offline cache is keyed independently per city / per near-me coordinate.
public enum GigScope: Equatable, Sendable {
  /// A named city (case-insensitive match on venue city, server-side).
  case city(String)
  /// "Near me" — haversine radius around a coordinate (server-side filter).
  case near(latitude: Double, longitude: Double, radiusKm: Double)

  /// The per-scope cache key stored in GigsSettings.
  public var cacheKey: String {
    switch self {
    case let .city(name):
      return "city:\(name.lowercased())"
    case let .near(latitude, longitude, radiusKm):
      // Coarsen coordinates so tiny GPS jitter still hits the same cache.
      let roundedLat = (latitude * 100).rounded() / 100
      let roundedLon = (longitude * 100).rounded() / 100
      return "near:\(roundedLat),\(roundedLon),\(Int(radiusKm))"
    }
  }
}

// MARK: - GigsServiceError

public enum GigsServiceError: Error, Equatable {
  case unreachable
  case decodingFailed
  case badResponse(statusCode: Int)
  case notConfigured
}

// MARK: - GigsService

public final class GigsService: @unchecked Sendable {
  private let serverUrl: String
  private let settings: GigsSettings
  private let gatewaySettings: AdjacencyGatewaySettings
  private let session: URLSession

  /// The gateway routes `/gigs/*` to the gigs-sidecar (spec §1.2).
  public static let gatewaySidecarPathPrefix = "/gigs"
  /// The sidecar's own events path (spec §1.2).
  public static let eventsPath = "/api/gigs/events"

  public init(
    serverUrl: String,
    settings: GigsSettings = .shared,
    gatewaySettings: AdjacencyGatewaySettings = .shared,
    session: URLSession = DiscoveryURLSession.fastFail
  ) {
    self.serverUrl = serverUrl
    self.settings = settings
    self.gatewaySettings = gatewaySettings
    self.session = session
  }

  /// Fetch upcoming events for a scope, up to `limit`, `daysAhead` out.
  /// On success the result is cached per-scope. Errors propagate — the caller
  /// (GigsVC) decides whether to fall back to the cache.
  public func fetchEvents(
    scope: GigScope,
    daysAhead: Int = 120,
    limit: Int = 200
  ) async throws
    -> [GigEvent] {
    guard let requestURL = makeRequestURL(scope: scope, daysAhead: daysAhead, limit: limit)
    else { throw GigsServiceError.notConfigured }

    var request = URLRequest(url: requestURL)
    if let route = gatewaySettings.activeRoute {
      request.setValue(route.apiKey, forHTTPHeaderField: AdjacencyGatewayRoute.apiKeyHeaderName)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw GigsServiceError.unreachable
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw GigsServiceError.unreachable
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw GigsServiceError.badResponse(statusCode: httpResponse.statusCode)
    }

    let events = try Self.parseEvents(from: data)
    settings.cacheResponse(events, forScope: scope.cacheKey)
    return events
  }

  /// The last cached response for a scope (for offline / error fallback).
  public func cachedResponse(for scope: GigScope) -> GigsCachedResponse? {
    settings.cachedResponse(forScope: scope.cacheKey)
  }

  // MARK: - Parsing (shared with unit tests)

  private static let log = Logger(subsystem: "de.amperfy.gigs", category: "GigsService")

  /// Decode the event-array JSON TOLERANTLY: a single malformed element is
  /// skipped (with a debug log) instead of throwing away the whole scope. Real
  /// Ticketmaster data has ~5% of rows that break the frozen contract (null
  /// venue/city, date-only startsAt) — those degraded-but-usable rows now
  /// survive via optional fields + date-only parsing, and only a truly
  /// undecodable row (e.g. missing id/url) is dropped. A response that isn't a
  /// JSON array at all (or isn't JSON) still throws `.decodingFailed`.
  ///
  /// Sorted date-ascending so every caller (live + cache) gets the same order
  /// the view sections on.
  public static func parseEvents(from data: Data) throws -> [GigEvent] {
    // First establish the payload is a JSON array; a non-array (or non-JSON)
    // body is a genuine contract/transport failure and should surface.
    guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
      throw GigsServiceError.decodingFailed
    }

    let decoder = GigsResponseDecoder.make()
    var events: [GigEvent] = []
    var skipped = 0
    for element in rawArray {
      guard let elementData = try? JSONSerialization.data(withJSONObject: element) else {
        skipped += 1
        continue
      }
      do {
        let event = try decoder.decode(GigEvent.self, from: elementData)
        events.append(event)
      } catch {
        skipped += 1
        log.debug("Skipping malformed gig event: \(error.localizedDescription, privacy: .public)")
      }
    }
    if skipped > 0 {
      log
        .debug(
          "Skipped \(skipped, privacy: .public) malformed gig event(s) of \(rawArray.count, privacy: .public)"
        )
    }
    return events.sorted { $0.startsAt < $1.startsAt }
  }

  // MARK: - URL building

  private func makeRequestURL(scope: GigScope, daysAhead: Int, limit: Int) -> URL? {
    var queryItems = [
      URLQueryItem(name: "daysAhead", value: String(daysAhead)),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    switch scope {
    case let .city(name):
      queryItems.append(URLQueryItem(name: "city", value: name))
    case let .near(latitude, longitude, radiusKm):
      queryItems.append(URLQueryItem(name: "lat", value: String(latitude)))
      queryItems.append(URLQueryItem(name: "lon", value: String(longitude)))
      queryItems.append(URLQueryItem(name: "radiusKm", value: String(Int(radiusKm))))
    }

    if let route = gatewaySettings.activeRoute {
      return Self.gatewayURL(route: route, queryItems: queryItems)
    }
    return directURL(queryItems: queryItems)
  }

  /// `{gateway}/gigs/api/gigs/events?...` — the same rebasing shape as
  /// AdjacencyGatewayRoute.url(sidecarPath:), but with the `/gigs` prefix.
  static func gatewayURL(route: AdjacencyGatewayRoute, queryItems: [URLQueryItem]) -> URL? {
    guard var components = URLComponents(url: route.baseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    let basePath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = basePath + gatewaySidecarPathPrefix + eventsPath
    components.queryItems = queryItems
    return components.url
  }

  /// `http(s)://{server host}:{gigs port}/api/gigs/events?...`
  private func directURL(queryItems: [URLQueryItem]) -> URL? {
    guard let serverURLValue = URL(string: serverUrl), let host = serverURLValue.host
    else { return nil }
    var components = URLComponents()
    components.scheme = serverURLValue.scheme ?? "http"
    components.host = host
    components.port = settings.port
    components.path = Self.eventsPath
    components.queryItems = queryItems
    return components.url
  }
}
