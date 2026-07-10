//
//  GigsModels.swift
//  AmperfyKit
//
//  Codable models for the gigs-sidecar event JSON (spec §1.2, frozen
//  contract). One event = one upcoming live show for a monitored artist,
//  already deduped + geo-filtered server-side. The app only reads; it never
//  posts events.
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

// MARK: - GigEvent

/// One upcoming live show. Mirrors the frozen event JSON (spec §1.2):
/// `{id, artistId, artistName, priorityScore, venueName, city, countryCode,
///   latitude, longitude, startsAt (ISO8601 UTC), url, source, fetchedAt}`.
///
/// Codable so it can be both decoded from the sidecar and re-encoded into the
/// per-scope offline cache (`GigsSettings`) without a second DTO.
public struct GigEvent: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public let artistId: String
  public let artistName: String
  public let priorityScore: Double?
  /// Venue name — OPTIONAL: real Ticketmaster rows can omit it (~12 of 503 in
  /// the round-1 dataset). Nil renders as a "TBA"-style fallback in the UI.
  public let venueName: String?
  /// City — OPTIONAL for the same reason (~5 null rows observed). Nil rows still
  /// belong to the scope they were fetched under and must still render.
  public let city: String?
  public let countryCode: String?
  public let latitude: Double?
  public let longitude: Double?
  /// The instant the show starts. For a date-only `startsAt` ("2026-07-30") this
  /// is start-of-day in UTC and `isAllDay` is true, so the UI shows the date
  /// without a time and sorting still works.
  public let startsAt: Date
  /// True when the source gave only a calendar date (no time) — render date-only.
  public let isAllDay: Bool
  /// Deep ticket link — opened in Safari on tap.
  public let url: String
  /// Source attribution (e.g. `ticketmaster`, `skiddle`, `bandsintown`).
  public let source: String
  /// When this event was fetched from its source — drives "as of" wording.
  public let fetchedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id, artistId, artistName, priorityScore, venueName, city, countryCode
    case latitude, longitude, startsAt, url, source, fetchedAt
  }

  public init(
    id: String,
    artistId: String,
    artistName: String,
    priorityScore: Double?,
    venueName: String?,
    city: String?,
    countryCode: String?,
    latitude: Double?,
    longitude: Double?,
    startsAt: Date,
    isAllDay: Bool = false,
    url: String,
    source: String,
    fetchedAt: Date?
  ) {
    self.id = id
    self.artistId = artistId
    self.artistName = artistName
    self.priorityScore = priorityScore
    self.venueName = venueName
    self.city = city
    self.countryCode = countryCode
    self.latitude = latitude
    self.longitude = longitude
    self.startsAt = startsAt
    self.isAllDay = isAllDay
    self.url = url
    self.source = source
    self.fetchedAt = fetchedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.artistId = try container.decode(String.self, forKey: .artistId)
    self.artistName = try container.decode(String.self, forKey: .artistName)
    self.priorityScore = try container.decodeIfPresent(Double.self, forKey: .priorityScore)
    self.venueName = try container.decodeIfPresent(String.self, forKey: .venueName)
    self.city = try container.decodeIfPresent(String.self, forKey: .city)
    self.countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
    self.latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
    self.longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    self.url = try container.decode(String.self, forKey: .url)
    self.source = try container.decode(String.self, forKey: .source)
    self.fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)

    // Accept both a full ISO8601 instant and a date-only "yyyy-MM-dd". The
    // per-key raw-string parse lets us flag the all-day case without a second
    // custom decoding strategy on the whole container.
    let rawStart = try container.decode(String.self, forKey: .startsAt)
    let parsed = GigsDateParsing.parse(rawStart)
    guard let parsed else {
      throw DecodingError.dataCorruptedError(
        forKey: .startsAt,
        in: container,
        debugDescription: "Not an ISO8601 instant or yyyy-MM-dd date: \(rawStart)"
      )
    }
    self.startsAt = parsed.date
    self.isAllDay = parsed.isAllDay
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(artistId, forKey: .artistId)
    try container.encode(artistName, forKey: .artistName)
    try container.encodeIfPresent(priorityScore, forKey: .priorityScore)
    try container.encodeIfPresent(venueName, forKey: .venueName)
    try container.encodeIfPresent(city, forKey: .city)
    try container.encodeIfPresent(countryCode, forKey: .countryCode)
    try container.encodeIfPresent(latitude, forKey: .latitude)
    try container.encodeIfPresent(longitude, forKey: .longitude)
    // Re-encode date-only events as date-only so a cache round-trip preserves
    // the all-day flag; instants keep their full ISO8601 form.
    if isAllDay {
      try container.encode(GigsDateParsing.dateOnlyString(from: startsAt), forKey: .startsAt)
    } else {
      try container.encode(GigsDateParsing.instantString(from: startsAt), forKey: .startsAt)
    }
    try container.encode(url, forKey: .url)
    try container.encode(source, forKey: .source)
    try container.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
  }

  /// A parsed ticket URL, or nil if the string isn't a usable absolute URL.
  public var ticketURL: URL? { URL(string: url) }
}

// MARK: - GigsDateParsing

/// Shared date parsing for the gigs contract. Real-world sources give us three
/// shapes we must all accept: a full ISO8601 instant with fractional seconds, a
/// plain ISO8601 instant, and a bare calendar date "yyyy-MM-dd" (date-only /
/// all-day). Used by both `GigEvent`'s own `startsAt` decode (which needs the
/// all-day flag) and the decoder's `fetchedAt` strategy (which just needs a
/// `Date`).
public enum GigsDateParsing {
  /// The result of parsing a `startsAt` string.
  public struct Parsed {
    public let date: Date
    public let isAllDay: Bool
  }

  /// Parse any of the three accepted shapes, or nil if none match.
  public static func parse(_ raw: String) -> Parsed? {
    if let instant = iso8601WithFractional.date(from: raw)
      ?? iso8601Plain.date(from: raw) {
      return Parsed(date: instant, isAllDay: false)
    }
    if let dateOnly = dateOnlyFormatter.date(from: raw) {
      return Parsed(date: dateOnly, isAllDay: true)
    }
    return nil
  }

  /// Parse to a plain `Date` (used for `fetchedAt`; all-day dates collapse to
  /// start-of-day UTC just like `parse`).
  public static func date(from raw: String) -> Date? {
    parse(raw)?.date
  }

  /// A full ISO8601 instant string (for encoding timed events into the cache).
  public static func instantString(from date: Date) -> String {
    iso8601Plain.string(from: date)
  }

  /// A "yyyy-MM-dd" string (for encoding date-only/all-day events).
  public static func dateOnlyString(from date: Date) -> String {
    dateOnlyFormatter.string(from: date)
  }

  // Immutable after construction and only read (thread-safe usage), so the
  // non-Sendable formatter types are safe to share under strict concurrency.
  nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  // A date-only "2026-07-30" is interpreted as start-of-day UTC so sorting and
  // week-grouping stay deterministic regardless of device timezone.
  nonisolated(unsafe) private static let dateOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

// MARK: - GigsResponseDecoder

/// The JSON decoder configured for the gigs contract. `GigEvent.startsAt` has
/// its own per-key decode (to capture the all-day flag); this strategy handles
/// every OTHER date key on the type — currently `fetchedAt` — and accepts the
/// same three shapes for robustness. Shared by the live client and the
/// fixture-driven unit tests so both parse identically.
public enum GigsResponseDecoder {
  public static func make() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let raw = try container.decode(String.self)
      if let date = GigsDateParsing.date(from: raw) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Not an ISO8601 date: \(raw)"
      )
    }
    return decoder
  }
}

// MARK: - GigsResponseEncoder

/// The matching encoder for writing events into the offline cache — ISO8601 so
/// a cached blob round-trips through `GigsResponseDecoder` unchanged.
public enum GigsResponseEncoder {
  public static func make() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
