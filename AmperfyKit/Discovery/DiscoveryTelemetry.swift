//
//  DiscoveryTelemetry.swift
//  AmperfyKit
//
//  Lightweight in-memory ring-buffer recorder for the Discovery feature
//  (build-60 user feedback): last 20 deals with per-stage timings, last 40
//  sprite fetches. Thread-safe via a single NSLock; zero cost when idle —
//  nothing is recorded unless a deal or sprite fetch actually happens, and
//  nothing is ever persisted. Record types: DiscoveryTelemetryRecords.swift.
//  Surfaced by Settings > Discovery Diagnostics.
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

// MARK: - DiscoveryURLSession

/// Dedicated fast-fail URLSession for all sidecar traffic (similar-* pools,
/// sprite manifests, the diagnostics health check). `URLSession.shared`'s
/// default 60s request timeout made an unreachable sidecar stall deals for
/// minutes instead of failing fast to the on-device fallback.
public enum DiscoveryURLSession {
  public static let requestTimeoutSeconds: TimeInterval = 5
  public static let resourceTimeoutSeconds: TimeInterval = 10

  public static let fastFail: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeoutSeconds
    configuration.timeoutIntervalForResource = resourceTimeoutSeconds
    return URLSession(configuration: configuration)
  }()
}

// MARK: - DiscoveryTelemetry

/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
public final class DiscoveryTelemetry: @unchecked Sendable {
  public static let shared = DiscoveryTelemetry()
  public static let maxDealRecords = 20
  public static let maxSpriteFetchRecords = 40
  /// Correlation header sent on every sidecar HTTP request under a deal, so
  /// client telemetry lines up with the sidecar's own access log.
  public static let dealIdHeaderName = "X-Deal-Id"

  private let lock = NSLock()
  private var dealsNewestLast: [DiscoveryDealRecord] = []
  private var spriteFetchesNewestLast: [DiscoverySpriteFetchRecord] = []
  private var openDealId: String?

  /// `shared` is the production instance; fresh instances exist for tests.
  public init() {}

  /// Elapsed whole milliseconds since `start` — the one timing helper every
  /// instrumentation site uses.
  public static func millisecondsSince(_ start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
  }

  // MARK: Deals

  /// Opens a new deal record and returns its short (8-hex) correlation id.
  /// Any prior still-open deal is finalized as-is ("in flight" served-by).
  @discardableResult
  public func beginDeal(
    trigger: String,
    seedDescription: String,
    kindDescription: String
  )
    -> String {
    let dealId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
      .lowercased()
    let record = DiscoveryDealRecord(
      dealId: dealId,
      startedAt: Date(),
      trigger: trigger,
      seedDescription: seedDescription,
      kindDescription: kindDescription,
      events: [],
      servedByPool: "in flight",
      fallbackTaken: false,
      dealtCount: 0,
      totalMs: 0
    )
    lock.withLock {
      dealsNewestLast.append(record)
      if dealsNewestLast.count > Self.maxDealRecords {
        dealsNewestLast.removeFirst(dealsNewestLast.count - Self.maxDealRecords)
      }
      openDealId = dealId
    }
    return dealId
  }

  /// Appends a stage event to the currently open deal. No-op when no deal is
  /// open (e.g. the diagnostics health check hitting the sidecar directly).
  public func appendDealEvent(label: String, detail: String, milliseconds: Int) {
    lock.withLock {
      guard let openDealId,
            let index = dealsNewestLast.lastIndex(where: { $0.dealId == openDealId })
      else { return }
      dealsNewestLast[index].events.append(DiscoveryStageEvent(
        label: label,
        detail: detail,
        milliseconds: milliseconds
      ))
    }
  }

  /// Finalizes the currently open deal with its summary line.
  public func completeDeal(
    servedByPool: String,
    fallbackTaken: Bool,
    dealtCount: Int,
    totalMs: Int
  ) {
    lock.withLock {
      guard let openDealId,
            let index = dealsNewestLast.lastIndex(where: { $0.dealId == openDealId })
      else { return }
      dealsNewestLast[index].servedByPool = servedByPool
      dealsNewestLast[index].fallbackTaken = fallbackTaken
      dealsNewestLast[index].dealtCount = dealtCount
      dealsNewestLast[index].totalMs = totalMs
      self.openDealId = nil
    }
  }

  /// The open deal's id, falling back to the most recent completed one — what
  /// sprite fetches (which arrive per-card, after the deal completed) send as
  /// their `X-Deal-Id` so server logs still correlate to the dealing session.
  public var currentDealId: String? {
    lock.withLock { openDealId ?? dealsNewestLast.last?.dealId }
  }

  // MARK: Sprite fetches

  public func recordSpriteFetch(urlString: String, outcome: String, milliseconds: Int) {
    lock.withLock {
      spriteFetchesNewestLast.append(DiscoverySpriteFetchRecord(
        id: UUID(),
        date: Date(),
        dealId: openDealId ?? dealsNewestLast.last?.dealId,
        urlString: urlString,
        outcome: outcome,
        milliseconds: milliseconds
      ))
      if spriteFetchesNewestLast.count > Self.maxSpriteFetchRecords {
        spriteFetchesNewestLast
          .removeFirst(spriteFetchesNewestLast.count - Self.maxSpriteFetchRecords)
      }
    }
  }

  // MARK: Reading

  public func dealRecordsNewestFirst() -> [DiscoveryDealRecord] {
    lock.withLock { dealsNewestLast.reversed() }
  }

  public func spriteFetchRecordsNewestFirst() -> [DiscoverySpriteFetchRecord] {
    lock.withLock { spriteFetchesNewestLast.reversed() }
  }

  public func plainTextDump() -> String {
    let deals = dealRecordsNewestFirst()
    let spriteFetches = spriteFetchRecordsNewestFirst()
    var sections = ["== Discovery Diagnostics (newest first) =="]
    sections.append("-- Deals (\(deals.count)) --")
    sections += deals.isEmpty ? ["(none)"] : deals.map(\.plainText)
    sections.append("-- Sprite fetches (\(spriteFetches.count)) --")
    sections += spriteFetches.isEmpty ? ["(none)"] : spriteFetches.map(\.plainText)
    return sections.joined(separator: "\n")
  }

  public func reset() {
    lock.withLock {
      dealsNewestLast = []
      spriteFetchesNewestLast = []
      openDealId = nil
    }
  }
}
