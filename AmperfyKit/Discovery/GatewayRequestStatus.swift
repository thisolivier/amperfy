//
//  GatewayRequestStatus.swift
//  AmperfyKit
//
//  Triage 2026-07-05 A2: "last gateway request" visibility for Settings —
//  the user had no way to tell the gateway was ever used. Derives a short
//  status from DiscoveryTelemetry's existing ring buffers (deal events and
//  sprite fetches recorded with "mode=gateway"); nothing new is recorded.
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

// MARK: - GatewayRequestStatus

/// The most recent gateway-routed request Discovery telemetry knows about.
public struct GatewayRequestStatus: Equatable, Sendable {
  /// When the request happened. Deal stage events carry no timestamp of their
  /// own, so for those this is the owning deal's start time — close enough
  /// for a relative-time display.
  public let date: Date
  /// Short human-readable outcome, e.g. "200", "key rejected (401)",
  /// "failed: Could not connect to the server."
  public let outcome: String

  public init(date: Date, outcome: String) {
    self.date = date
    self.outcome = outcome
  }
}

extension DiscoveryTelemetry {
  /// The marker both recording sites embed: `AdjacencySidecarClient` deal
  /// events ("mode=gateway url=... status=200" / "... error=msg") and
  /// `DeckSpriteManifestFetcher` sprite outcomes ("ready (8 slices)
  /// mode=gateway", "failed (status 401) mode=gateway", ...).
  public static let gatewayModeMarker = "mode=gateway"

  /// Newest gateway-routed request across both ring buffers, or nil when no
  /// gateway request was ever made this launch (telemetry is in-memory only).
  public func lastGatewayRequestStatus() -> GatewayRequestStatus? {
    // Both accessors return newest-first, so the first hit in each is that
    // buffer's newest; then pick the later of the two.
    let newestDealStatus = dealRecordsNewestFirst()
      .lazy
      .compactMap { deal -> GatewayRequestStatus? in
        deal.events.last { $0.detail.contains(Self.gatewayModeMarker) }
          .map { GatewayRequestStatus(
            date: deal.startedAt,
            outcome: Self.shortGatewayOutcome(from: $0.detail)
          ) }
      }
      .first
    let newestSpriteStatus = spriteFetchRecordsNewestFirst()
      .first { $0.outcome.contains(Self.gatewayModeMarker) }
      .map { GatewayRequestStatus(
        date: $0.date,
        outcome: Self.shortGatewayOutcome(from: $0.outcome)
      ) }
    switch (newestDealStatus, newestSpriteStatus) {
    case (nil, nil): return nil
    case let (status?, nil): return status
    case let (nil, status?): return status
    case let (dealStatus?, spriteStatus?):
      return dealStatus.date >= spriteStatus.date ? dealStatus : spriteStatus
    }
  }

  /// Collapses a raw telemetry detail/outcome string into the short form the
  /// Settings status line shows. Internal (not private) for direct unit tests.
  static func shortGatewayOutcome(from rawOutcome: String) -> String {
    // "status=200" (deal events) or "status 401" (sprite "failed (status 401)").
    if let statusMatch = rawOutcome.firstMatch(of: /status[= ](\d{3})/) {
      let statusCode = String(statusMatch.1)
      if statusCode == "401" || statusCode == "403" {
        return "key rejected (\(statusCode))"
      }
      return statusCode
    }
    // Sprite successes / lazy-render 404s never spell out their status code.
    if rawOutcome.hasPrefix("ready") { return "200" }
    if rawOutcome.hasPrefix("unavailable (404") { return "404 (sprite not rendered yet)" }
    // Deal-event transport failure: "mode=gateway url=... error=<msg>".
    if let errorRange = rawOutcome.range(of: "error=") {
      return "failed: \(rawOutcome[errorRange.upperBound...])"
    }
    // Sprite transport failure: "failed (<msg>) mode=gateway".
    if rawOutcome.hasPrefix("failed (") {
      let message = rawOutcome
        .replacingOccurrences(of: " \(gatewayModeMarker)", with: "")
        .dropFirst("failed (".count)
        .dropLast() // trailing ")"
      return "failed: \(message)"
    }
    return rawOutcome.replacingOccurrences(of: " \(gatewayModeMarker)", with: "")
  }
}
