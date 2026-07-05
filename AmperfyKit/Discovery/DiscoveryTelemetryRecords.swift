//
//  DiscoveryTelemetryRecords.swift
//  AmperfyKit
//
//  Record types for the Discovery telemetry ring buffers (build-60 user
//  feedback: production-device debuggability for "slow deals" and "missing
//  previews", surfaced by the Settings > Discovery Diagnostics screen).
//  The recorder itself is DiscoveryTelemetry.swift.
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

// MARK: - DiscoveryStageEvent

/// One timed step inside a deal's timeline (seed resolution, a pool fetch, a
/// sidecar HTTP request, resolve+interleave, ...). Free-form label/detail so
/// each layer can report what it knows without a rigid cross-layer schema.
public struct DiscoveryStageEvent: Sendable {
  public let label: String
  public let detail: String
  public let milliseconds: Int

  public init(label: String, detail: String, milliseconds: Int) {
    self.label = label
    self.detail = detail
    self.milliseconds = milliseconds
  }
}

// MARK: - DiscoveryDealRecord

/// The full stage timeline of one user-perceived deal (initial deal, Deal
/// More, or refresh) — including the silent on-device fallback pass, when one
/// was taken. `dealId` is the short correlation id sent to the sidecar as the
/// `X-Deal-Id` header on every HTTP request made under this deal.
public struct DiscoveryDealRecord: Sendable, Identifiable {
  public var id: String { dealId }
  public let dealId: String
  public let startedAt: Date
  public let trigger: String
  public let seedDescription: String
  public let kindDescription: String
  public var events: [DiscoveryStageEvent]
  /// "sidecar" | "on-device fallback" | "none" ("in flight" while open).
  public var servedByPool: String
  public var fallbackTaken: Bool
  public var dealtCount: Int
  public var totalMs: Int
}

// MARK: - DiscoverySpriteFetchRecord

/// One sprite-manifest fetch (or sprite-audio player load failure): what URL
/// was tried, what happened, how long it took, and under which deal.
public struct DiscoverySpriteFetchRecord: Sendable, Identifiable {
  public let id: UUID
  public let date: Date
  public let dealId: String?
  public let urlString: String
  public let outcome: String
  public let milliseconds: Int
}

// MARK: - Plaintext formatting

extension DiscoveryDealRecord {
  public var plainText: String {
    var lines = [
      "[\(Self.timestampFormatter.string(from: startedAt))] deal \(dealId) " +
        "trigger=\(trigger) seed=\(seedDescription) kind=\(kindDescription)",
      "  served-by=\(servedByPool) fallback=\(fallbackTaken ? "yes" : "no") " +
        "dealt=\(dealtCount) total=\(totalMs)ms",
    ]
    lines += events.map { "  \($0.label): \($0.detail) (\($0.milliseconds)ms)" }
    return lines.joined(separator: "\n")
  }

  static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()
}

extension DiscoverySpriteFetchRecord {
  public var plainText: String {
    "[\(DiscoveryDealRecord.timestampFormatter.string(from: date))] " +
      "sprite deal=\(dealId ?? "-") \(outcome) (\(milliseconds)ms) url=\(urlString)"
  }
}
