//
//  GigsSettings.swift
//  AmperfyKit
//
//  UserDefaults-backed settings for the Gigs feature (spec §1.3): the enable
//  flag, the user-managed city list that forms the default scope, the direct
//  sidecar port fallback, and the per-scope offline cache of the last
//  successful response. Mirrors the storage pattern of
//  AdjacencySidecarSettings / AdjacencyGatewaySettings.
//
//  Networking reuses the SHARED gateway credentials (AdjacencyGatewaySettings)
//  — the gateway fronts both `/adjacency/*` and `/gigs/*` behind one URL+key
//  (spec §1.2/§1.3) — so there is deliberately no separate gigs URL/key here.
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

// MARK: - GigsCachedResponse

/// A cached successful gigs response for one scope, with the instant it was
/// stored — the Gigs view renders this offline and shows an "as of" timestamp.
public struct GigsCachedResponse: Codable, Sendable {
  public let events: [GigEvent]
  public let storedAt: Date

  public init(events: [GigEvent], storedAt: Date) {
    self.events = events
    self.storedAt = storedAt
  }
}

// MARK: - GigsSettings

/// Local-only Gigs settings, backed by UserDefaults.
public final class GigsSettings: @unchecked Sendable {
  public static let shared = GigsSettings()

  /// Direct-mode sidecar port when the shared gateway is not configured.
  /// Gigs-sidecar defaults: 8791 prod / 8792 QA (spec §1.2). We default to the
  /// prod port, matching how AdjacencySidecarSettings defaults to 8787/prod.
  public static let defaultPort = 8791

  private let enabledKey = "amperfy.fork.gigs.enabled"
  private let citiesKey = "amperfy.fork.gigs.cities"
  private let portKey = "amperfy.fork.gigs.sidecarPort"
  private let cachePrefix = "amperfy.fork.gigs.cache."

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Whether the Gigs feature is enabled. Off by default — the user opts in
  /// (and the sidecar isn't universally deployed yet).
  public var isEnabled: Bool {
    get { defaults.bool(forKey: enabledKey) }
    set { defaults.set(newValue, forKey: enabledKey) }
  }

  /// The user-managed city list forming the default scope. Empty until the
  /// user adds one (first-run empty state prompts add-city / use-location).
  public var cities: [String] {
    get { defaults.stringArray(forKey: citiesKey) ?? [] }
    set { defaults.set(newValue, forKey: citiesKey) }
  }

  /// Add a city (trimmed, case-insensitively de-duplicated). No-op on blanks.
  /// Returns `true` when a city was actually added, `false` when the input was
  /// blank or already followed — so callers can give "Already following <city>"
  /// feedback instead of silently swallowing a duplicate tap.
  @discardableResult
  public func addCity(_ city: String) -> Bool {
    let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var current = cities
    guard !current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return false }
    current.append(trimmed)
    cities = current
    return true
  }

  public func removeCity(_ city: String) {
    cities = cities.filter { $0.caseInsensitiveCompare(city) != .orderedSame }
  }

  /// The gigs-sidecar port for direct (non-gateway) mode.
  public var port: Int {
    get {
      let stored = defaults.integer(forKey: portKey)
      return stored == 0 ? Self.defaultPort : stored
    }
    set { defaults.set(newValue, forKey: portKey) }
  }

  // MARK: - Offline cache (per scope)

  private func cacheKey(forScope scope: String) -> String {
    cachePrefix + scope
  }

  /// Store the latest successful response for a scope (e.g. `city:London` or
  /// `near:51.5,-0.1`). Silently no-ops if encoding fails — caching must never
  /// break a live fetch.
  public func cacheResponse(_ events: [GigEvent], forScope scope: String) {
    let cached = GigsCachedResponse(events: events, storedAt: Date())
    guard let data = try? GigsResponseEncoder.make().encode(cached) else { return }
    defaults.set(data, forKey: cacheKey(forScope: scope))
  }

  /// The last cached response for a scope, or nil if none / undecodable.
  public func cachedResponse(forScope scope: String) -> GigsCachedResponse? {
    guard let data = defaults.data(forKey: cacheKey(forScope: scope)) else { return nil }
    return try? GigsResponseDecoder.make().decode(GigsCachedResponse.self, from: data)
  }
}
