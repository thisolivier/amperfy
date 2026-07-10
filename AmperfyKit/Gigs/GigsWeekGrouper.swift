//
//  GigsWeekGrouper.swift
//  AmperfyKit
//
//  Pure grouping logic for the Gigs view (spec §1.3): sort events date
//  ascending and split into one section per calendar week. Kept free of UIKit
//  so it is directly unit-testable against fixtures.
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

// MARK: - GigsWeekSection

/// One week's worth of events, keyed by the start-of-week date.
public struct GigsWeekSection: Sendable, Equatable {
  public let weekStart: Date
  public let events: [GigEvent]

  public init(weekStart: Date, events: [GigEvent]) {
    self.weekStart = weekStart
    self.events = events
  }
}

// MARK: - GigsWeekGrouper

public enum GigsWeekGrouper {
  /// Group events into weekly sections ascending by week, events within a
  /// week ascending by start. De-duplicates first (see `dedupe`).
  public static func group(
    events: [GigEvent],
    calendar: Calendar = .current
  )
    -> [GigsWeekSection] {
    let deduped = dedupe(events)

    var buckets: [Date: [GigEvent]] = [:]
    for event in deduped {
      let weekStart = startOfWeek(for: event.startsAt, calendar: calendar)
      buckets[weekStart, default: []].append(event)
    }

    return buckets.keys.sorted().map { weekStart in
      let sorted = buckets[weekStart]!.sorted { $0.startsAt < $1.startsAt }
      return GigsWeekSection(weekStart: weekStart, events: sorted)
    }
  }

  /// Source display preference — mirrors the sidecar's SOURCE_PREFERENCE
  /// (gigs-sidecar/dedupe.py). When a merge of several city fetches (or a
  /// raw API that served both rows of a cross-source pair) yields near-
  /// duplicates, the most-preferred source's row survives as the display row.
  static let sourcePreference = ["ticketmaster", "skiddle", "bandsintown"]
  /// Cross-source starts within this window (seconds) count as the same gig.
  static let dedupeWindowSeconds: TimeInterval = 3600

  /// De-duplicate events. First collapses exact `id` repeats (a multi-city
  /// merge can repeat the SAME event), then collapses cross-source near-
  /// duplicates — same normalized artist + venue with starts within 1h —
  /// keeping the most-preferred source's row (QA B-P2-4: the client used to
  /// surface the Skiddle variant; the sidecar prefers Ticketmaster and so must
  /// the client). Deterministic: input order does not change which row wins.
  static func dedupe(_ events: [GigEvent]) -> [GigEvent] {
    // 1) exact-id collapse (stable, keeps first occurrence).
    var seenIds = Set<String>()
    let idUnique = events.filter { seenIds.insert($0.id).inserted }

    // 2) cluster by (normalized artist, normalized venue), then split each
    //    cluster by the 1h start window; pick the preferred-source member.
    var clustersByKey: [String: [GigEvent]] = [:]
    var keyOrder: [String] = []
    for event in idUnique {
      let key = normalizeKeyText(event.artistName) + "\u{1F}" + normalizeKeyText(event.venueName)
      if clustersByKey[key] == nil { keyOrder.append(key) }
      clustersByKey[key, default: []].append(event)
    }

    var result: [GigEvent] = []
    for key in keyOrder {
      let group = clustersByKey[key] ?? []
      result.append(contentsOf: mergeWithinWindow(group))
    }
    return result
  }

  /// Merge same-artist+venue rows whose starts fall within the dedupe window,
  /// keeping the preferred-source member of each time cluster.
  private static func mergeWithinWindow(_ rows: [GigEvent]) -> [GigEvent] {
    let sorted = rows.sorted { $0.startsAt < $1.startsAt }
    var clusters: [[GigEvent]] = []
    for row in sorted {
      if let index = clusters.firstIndex(where: { cluster in
        guard let anchor = cluster.first else { return false }
        return abs(row.startsAt.timeIntervalSince(anchor.startsAt)) <= dedupeWindowSeconds
      }) {
        clusters[index].append(row)
      } else {
        clusters.append([row])
      }
    }
    return clusters.map(canonicalRow)
  }

  /// The canonical (display) row for a cluster: the most-preferred source,
  /// ties broken by the smaller id for determinism.
  private static func canonicalRow(_ cluster: [GigEvent]) -> GigEvent {
    cluster.min { lhs, rhs in
      let lhsRank = sourceRank(lhs.source)
      let rhsRank = sourceRank(rhs.source)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return lhs.id < rhs.id
    } ?? cluster[0]
  }

  private static func sourceRank(_ source: String) -> Int {
    sourcePreference.firstIndex(of: source.lowercased()) ?? sourcePreference.count
  }

  /// Normalize artist/venue text for keying: casefold, drop punctuation, drop a
  /// standalone "the", collapse whitespace. Mirrors the sidecar's
  /// `_normalize_key_text` so client and server cluster identically.
  static func normalizeKeyText(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    let lowered = value.lowercased()
    let unpunctuated = lowered.unicodeScalars.map { scalar -> Character in
      (CharacterSet.alphanumerics.contains(scalar) || scalar == " ")
        ? Character(scalar)
        : " "
    }
    let collapsed = String(unpunctuated)
      .split(separator: " ")
      .filter { $0 != "the" }
      .joined(separator: " ")
    return collapsed
  }

  /// The first instant of the calendar week containing `date`.
  static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
    let components = calendar.dateComponents(
      [.yearForWeekOfYear, .weekOfYear],
      from: date
    )
    return calendar.date(from: components) ?? date
  }
}
