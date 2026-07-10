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
  public let venueName: String
  public let city: String
  public let countryCode: String?
  public let latitude: Double?
  public let longitude: Double?
  /// ISO8601 UTC instant the show starts (contract: `startsAt`).
  public let startsAt: Date
  /// Deep ticket link — opened in Safari on tap.
  public let url: String
  /// Source attribution (e.g. `ticketmaster`, `skiddle`, `bandsintown`).
  public let source: String
  /// When this event was fetched from its source — drives "as of" wording.
  public let fetchedAt: Date?

  public init(
    id: String,
    artistId: String,
    artistName: String,
    priorityScore: Double?,
    venueName: String,
    city: String,
    countryCode: String?,
    latitude: Double?,
    longitude: Double?,
    startsAt: Date,
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
    self.url = url
    self.source = source
    self.fetchedAt = fetchedAt
  }

  /// A parsed ticket URL, or nil if the string isn't a usable absolute URL.
  public var ticketURL: URL? { URL(string: url) }
}

// MARK: - GigsResponseDecoder

/// The JSON decoder configured for the gigs contract: ISO8601 dates (with and
/// without fractional seconds, since sources vary). Shared by the live client
/// and the fixture-driven unit tests so both parse identically.
public enum GigsResponseDecoder {
  public static func make() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let raw = try container.decode(String.self)
      if let date = iso8601WithFractional.date(from: raw)
        ?? iso8601Plain.date(from: raw) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Not an ISO8601 date: \(raw)"
      )
    }
    return decoder
  }

  // Immutable after construction and only read (thread-safe usage), so the
  // non-Sendable formatter type is safe to share under strict concurrency.
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
