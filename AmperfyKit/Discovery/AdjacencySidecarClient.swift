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

  /// - Parameter serverUrl: the active account's Navidrome server URL string
  ///   (e.g. `account.serverUrl`). Only the host/scheme are kept; the port is
  ///   replaced with `settings.port`.
  public init(
    serverUrl: String,
    settings: AdjacencySidecarSettings = .shared,
    session: URLSession = .shared
  ) {
    self.session = session
    if let serverURLValue = URL(string: serverUrl), let host = serverURLValue.host {
      var components = URLComponents()
      components.scheme = serverURLValue.scheme ?? "http"
      components.host = host
      components.port = settings.port
      self.baseURL = components.url
    } else {
      self.baseURL = nil
    }
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

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(from: requestURL)
    } catch {
      throw DeckPoolError.unreachable
    }

    guard let httpResponse = response as? HTTPURLResponse,
          (200 ..< 300).contains(httpResponse.statusCode) else {
      // Any non-2xx is unreachable for these two endpoints — unlike
      // sprite-manifest, there is no meaningful 404 case here.
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
