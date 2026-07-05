//
//  AdjacencySidecarClient.swift
//  AmperfyKit
//
//  FamiliarPoolProviding backed by adjacency-sidecar's collection-similarity
//  endpoints (docs/contracts/adjacency-sidecar-api.md §3.1-3.2). Plain
//  URLSession + Codable — deliberately no Alamofire; that's Subsonic-specific
//  plumbing (see SubsonicServerApi) not worth pulling in for two simple GETs,
//  per this project's minimal-dependency convention.
//
//  Base URL assumption (v1, documented here — no cross-host config): the
//  adjacency-sidecar runs on the SAME HOST as the active account's Navidrome
//  server, on a different, separately-configured port (AdjacencySidecarSettings,
//  default 8787/prod, 8788/QA). The host is captured once at init time from the
//  server URL string the caller supplies (see the account.serverUrl accessor
//  chain: `Account.serverUrl` -> `managedObject.serverUrl` directly, no extra
//  hops through LoginCredentials needed since Account already exposes it). If
//  the active account changes, the caller is expected to construct a fresh
//  client — this class does not observe account changes.
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

// MARK: - AdjacencySidecarClient

public final class AdjacencySidecarClient: FamiliarPoolProviding {
  private let baseURL: URL?
  private let session: URLSession
  private let telemetry: DiscoveryTelemetry

  /// - Parameter serverUrl: the active account's Navidrome server URL string
  ///   (e.g. `account.serverUrl`). Only the host/scheme are kept; the port is
  ///   replaced with `settings.port`.
  /// - Parameter session: defaults to the dedicated 5s-timeout session — an
  ///   unreachable sidecar must fail fast to the on-device fallback, not
  ///   stall deals for `URLSession.shared`'s 60s default.
  public init(
    serverUrl: String,
    settings: AdjacencySidecarSettings = .shared,
    session: URLSession = DiscoveryURLSession.fastFail,
    telemetry: DiscoveryTelemetry = .shared
  ) {
    self.session = session
    self.telemetry = telemetry
    self.baseURL = Self.deriveBaseURL(serverUrl: serverUrl, settings: settings)
  }

  /// `http(s)://{server host}:{configured sidecar port}` — shared with the
  /// Discovery Diagnostics screen's "Test sidecar connection" health check so
  /// the diagnosed URL is exactly the one this client uses.
  public static func deriveBaseURL(
    serverUrl: String,
    settings: AdjacencySidecarSettings = .shared
  )
    -> URL? {
    guard let serverURLValue = URL(string: serverUrl), let host = serverURLValue.host
    else { return nil }
    var components = URLComponents()
    components.scheme = serverURLValue.scheme ?? "http"
    components.host = host
    components.port = settings.port
    return components.url
  }

  public func fetchCandidates(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  ) async throws
    -> [ScoredCandidate] {
    guard let requestURL = makeRequestURL(
      seedSongIds: seedSongIds,
      seedCollection: seedCollection,
      kind: kind,
      count: count
    ) else {
      throw DeckPoolError.unreachable
    }

    var request = URLRequest(url: requestURL)
    if let dealId = telemetry.currentDealId {
      request.setValue(dealId, forHTTPHeaderField: DiscoveryTelemetry.dealIdHeaderName)
    }

    let requestStart = DispatchTime.now()
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      telemetry.appendDealEvent(
        label: "sidecar request",
        detail: "url=\(requestURL.absoluteString) error=\(error.localizedDescription)",
        milliseconds: DiscoveryTelemetry.millisecondsSince(requestStart)
      )
      throw DeckPoolError.unreachable
    }
    telemetry.appendDealEvent(
      label: "sidecar request",
      detail: "url=\(requestURL.absoluteString) " +
        "status=\((response as? HTTPURLResponse)?.statusCode ?? -1)",
      milliseconds: DiscoveryTelemetry.millisecondsSince(requestStart)
    )

    guard let httpResponse = response as? HTTPURLResponse,
          (200 ..< 300).contains(httpResponse.statusCode) else {
      // Any non-2xx is unreachable for these two endpoints — CONFIRMED
      // against the real server source (server/adjacency-sidecar/server.py,
      // `_handle_similar_collections` / `_handle_similar_from_history`),
      // not just assumed: both handlers always respond via `_send_json(...)`
      // with the default `status=200`, even when the underlying query
      // (collections_query.get_similar_playlists/get_similar_albums,
      // history_query.get_similar_from_history) returns an empty list for a
      // seed with zero matches — a legitimate "no matches" seed comes back
      // as `200 []`, decoded below to an empty array, never a 404. 404 on
      // these routes only happens via `do_GET`'s catch-all for entirely
      // unrecognized paths (a routing/config bug on the client's side, e.g.
      // wrong host/port), so treating it as `.unreachable` here is correct
      // — unlike sprite-manifest, there is genuinely no "not-yet-rendered"
      // style 404 case for these two endpoints. (Investigated 2026-07 as
      // part of chasing a QA false "degraded pool" report from card 1 of
      // every deck; this policy was cleared as the cause — see
      // AdjacencySidecarClientTest's 404/connection-failure cases. The
      // leading suspect for that report instead is environmental:
      // `AdjacencySidecarSettings.port` defaults to 8787/prod with no
      // settings UI yet to switch a QA device to 8788 — see
      // AdjacencySidecarSettings.swift and the same class of bug already
      // found/fixed for the sprite-manifest port in
      // Amperfy/Screens/Discovery/DeckSpriteManifestFetcher.swift's history.)
      throw DeckPoolError.unreachable
    }

    do {
      let decoded = try JSONDecoder().decode([SidecarCollectionResult].self, from: data)
      return decoded.map {
        ScoredCandidate(
          collectionId: $0.collectionId,
          kind: DeckCandidateKind(rawValue: $0.kind) ?? kind,
          score: $0.score,
          // Filled in by the caller (DeckFusionEngine), which knows the
          // human-readable seed title; this client only ever sees ids.
          seedTitle: ""
        )
      }
    } catch {
      throw DeckPoolError.decodingFailed
    }
  }

  // MARK: - Private

  private func makeRequestURL(
    seedSongIds: [String],
    seedCollection: (id: String, kind: DeckCandidateKind)?,
    kind: DeckCandidateKind,
    count: Int
  )
    -> URL? {
    guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { return nil }

    var queryItems = [
      URLQueryItem(name: "kind", value: kind.rawValue),
      URLQueryItem(name: "count", value: String(count)),
    ]

    if let seedCollection {
      components.path = "/similar-collections"
      queryItems.append(URLQueryItem(name: "collectionId", value: seedCollection.id))
    } else {
      guard !seedSongIds.isEmpty else { return nil }
      components.path = "/similar-from-history"
      queryItems.append(URLQueryItem(
        name: "seedSongIds",
        value: seedSongIds.joined(separator: ",")
      ))
    }

    components.queryItems = queryItems
    return components.url
  }
}

// MARK: - SidecarCollectionResult

/// Mirrors `docs/contracts/adjacency-sidecar-api.md` §3.1's response shape,
/// shared by both `/similar-collections` and `/similar-from-history`.
private struct SidecarCollectionResult: Decodable {
  let collectionId: String
  let kind: String
  let score: Double
  let evidence: Evidence?

  struct Evidence: Decodable {
    let sharedTracks: Int
  }
}
