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
  /// week ascending by start. De-duplicates by event id first (a merge of
  /// several city fetches can repeat an event).
  public static func group(
    events: [GigEvent],
    calendar: Calendar = .current
  )
    -> [GigsWeekSection] {
    var seenIds = Set<String>()
    let deduped = events.filter { seenIds.insert($0.id).inserted }

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

  /// The first instant of the calendar week containing `date`.
  static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
    let components = calendar.dateComponents(
      [.yearForWeekOfYear, .weekOfYear],
      from: date
    )
    return calendar.date(from: components) ?? date
  }
}
