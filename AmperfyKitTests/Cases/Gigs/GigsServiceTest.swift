//
//  GigsServiceTest.swift
//  AmperfyKitTests
//
//  Parsing / grouping / caching tests for the Gigs feature, driven by the
//  fixture `gigs_events.json` (mirrors the frozen event JSON, spec §1.2). The
//  live sidecar is not exercised here — only the pure parse/group/cache paths,
//  which are what the offline-first Gigs view depends on.
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

@testable import AmperfyKit
import XCTest

// MARK: - GigsServiceTest

@MainActor
class GigsServiceTest: XCTestCase {
  private func fixtureData() -> Data {
    getTestFileData(name: "gigs_events", withExtension: "json")
  }

  func testParsesAllValidEventsFromFixture() throws {
    // The fixture has 7 rows: 6 valid (3 timed London + 1 date-only Warsaw +
    // 1 null-venue Montreal + 1 null-city Montreal) and 1 malformed (missing
    // id + url). Tolerant decoding keeps all 6 valid ones and drops only the bad.
    let events = try GigsService.parseEvents(from: fixtureData())
    XCTAssertEqual(events.count, 6)
    XCTAssertNil(events.first { $0.artistName == "Malformed — missing id and url" })
  }

  func testParsesEventFieldsCorrectly() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    let goose = try XCTUnwrap(events.first { $0.id == "evt-002" })
    XCTAssertEqual(goose.artistName, "Goose")
    XCTAssertEqual(goose.venueName, "The Roundhouse")
    XCTAssertEqual(goose.city, "London")
    XCTAssertEqual(goose.source, "skiddle")
    XCTAssertEqual(goose.countryCode, "GB")
    XCTAssertFalse(goose.isAllDay)
    XCTAssertNotNil(goose.ticketURL)
    XCTAssertEqual(goose.ticketURL?.absoluteString, "https://skiddle.example.com/evt-002")
  }

  func testEventsSortedDateAscending() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    let dates = events.map(\.startsAt)
    XCTAssertEqual(dates, dates.sorted())
  }

  func testParsesBothFractionalAndPlainISO8601() throws {
    // evt-002 uses fractional seconds, evt-001 does not — both must decode.
    let events = try GigsService.parseEvents(from: fixtureData())
    XCTAssertNotNil(events.first { $0.id == "evt-001" }?.startsAt)
    XCTAssertNotNil(events.first { $0.id == "evt-002" }?.startsAt)
  }

  func testMalformedEventIsSkippedNotFatal() throws {
    // The Montreal city scope in QA degraded to zero events because ONE bad row
    // threw for the whole array. Tolerant decoding must keep the good rows.
    let events = try GigsService.parseEvents(from: fixtureData())
    // Both Montreal rows (null venue, null city) survive.
    XCTAssertNotNil(events.first { $0.id == "evt-005-nullvenue" })
    XCTAssertNotNil(events.first { $0.id == "evt-006-nullcity" })
  }

  func testDateOnlyEventParsesAsAllDayAtStartOfDayUTC() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    let weeknd = try XCTUnwrap(events.first { $0.id == "evt-004-dateonly" })
    XCTAssertTrue(weeknd.isAllDay)
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: weeknd.startsAt
    )
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 7)
    XCTAssertEqual(components.day, 30)
    XCTAssertEqual(components.hour, 0)
    XCTAssertEqual(components.minute, 0)
    XCTAssertEqual(components.second, 0)
  }

  func testNullVenueAndCityDecodeAsNil() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    let nullVenue = try XCTUnwrap(events.first { $0.id == "evt-005-nullvenue" })
    XCTAssertNil(nullVenue.venueName)
    XCTAssertEqual(nullVenue.city, "Montreal")
    XCTAssertNil(nullVenue.latitude)
    XCTAssertNil(nullVenue.longitude)
    let nullCity = try XCTUnwrap(events.first { $0.id == "evt-006-nullcity" })
    XCTAssertEqual(nullCity.venueName, "MTELUS")
    XCTAssertNil(nullCity.city)
  }

  func testDateOnlyEventRoundTripsThroughCache() throws {
    // A date-only event must re-encode as date-only so the offline cache keeps
    // its all-day flag intact across a decode → encode → decode cycle.
    let events = try GigsService.parseEvents(from: fixtureData())
    let original = try XCTUnwrap(events.first { $0.id == "evt-004-dateonly" })
    let encoded = try GigsResponseEncoder.make().encode(original)
    let roundTripped = try GigsResponseDecoder.make().decode(GigEvent.self, from: encoded)
    XCTAssertEqual(roundTripped, original)
    XCTAssertTrue(roundTripped.isAllDay)
  }

  func testEmptyArrayParsesToNoEvents() throws {
    let events = try GigsService.parseEvents(from: Data("[]".utf8))
    XCTAssertTrue(events.isEmpty)
  }

  func testDecodingFailureThrows() {
    // A non-array body (or non-JSON) is a genuine contract/transport failure.
    let garbage = Data("not json".utf8)
    XCTAssertThrowsError(try GigsService.parseEvents(from: garbage)) { error in
      XCTAssertEqual(error as? GigsServiceError, .decodingFailed)
    }
    let notAnArray = Data("{\"unexpected\":\"object\"}".utf8)
    XCTAssertThrowsError(try GigsService.parseEvents(from: notAnArray)) { error in
      XCTAssertEqual(error as? GigsServiceError, .decodingFailed)
    }
  }

  func testWeekGrouperSplitsIntoWeeksAscending() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    // Use a fixed calendar (Gregorian, week starts Monday) so the assertion is
    // locale-independent: 2026-08-02 (Sun) is its own week; 2026-08-09 (Sun)
    // and 2026-08-14 (Fri) also each start a week under a Monday-first calendar.
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2 // Monday
    let sections = GigsWeekGrouper.group(events: events, calendar: calendar)
    XCTAssertFalse(sections.isEmpty)
    let weekStarts = sections.map(\.weekStart)
    XCTAssertEqual(weekStarts, weekStarts.sorted())
    // Each section's events are themselves ascending.
    for section in sections {
      let starts = section.events.map(\.startsAt)
      XCTAssertEqual(starts, starts.sorted())
    }
    // Total events preserved across sections.
    let total = sections.reduce(0) { $0 + $1.events.count }
    XCTAssertEqual(total, events.count)
  }

  func testWeekGrouperDeduplicatesById() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    let doubled = events + events // simulate a multi-city merge overlap
    let sections = GigsWeekGrouper.group(events: doubled)
    let total = sections.reduce(0) { $0 + $1.events.count }
    XCTAssertEqual(total, events.count)
  }
}

// MARK: - GigsSettingsTest

@MainActor
class GigsSettingsTest: XCTestCase {
  private var defaults: UserDefaults!
  private var settings: GigsSettings!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "GigsSettingsTest-\(UUID().uuidString)")
    settings = GigsSettings(defaults: defaults)
  }

  func testAddCityTrimsAndDeduplicatesCaseInsensitively() {
    settings.addCity("  London ")
    settings.addCity("london")
    settings.addCity("Manchester")
    XCTAssertEqual(settings.cities, ["London", "Manchester"])
  }

  func testAddBlankCityIsNoOp() {
    settings.addCity("   ")
    XCTAssertTrue(settings.cities.isEmpty)
  }

  func testRemoveCityCaseInsensitive() {
    settings.addCity("London")
    settings.removeCity("LONDON")
    XCTAssertTrue(settings.cities.isEmpty)
  }

  func testPortDefaultsToProdWhenUnset() {
    XCTAssertEqual(settings.port, GigsSettings.defaultPort)
  }

  func testCacheRoundTripsPerScope() throws {
    let events = try GigsService.parseEvents(
      from: getTestFileData(name: "gigs_events", withExtension: "json")
    )
    settings.cacheResponse(events, forScope: "city:london")
    let cached = settings.cachedResponse(forScope: "city:london")
    XCTAssertEqual(cached?.events.count, events.count)
    XCTAssertEqual(cached?.events.first?.id, events.first?.id)
    XCTAssertNil(settings.cachedResponse(forScope: "city:paris"))
  }
}

// MARK: - GigScopeTest

class GigScopeTest: XCTestCase {
  func testCityCacheKeyIsLowercased() {
    XCTAssertEqual(GigScope.city("London").cacheKey, "city:london")
  }

  func testNearCacheKeyCoarsensCoordinates() {
    let key = GigScope.near(latitude: 51.50731, longitude: -0.12775, radiusKm: 50).cacheKey
    XCTAssertEqual(key, "near:51.51,-0.13,50")
  }
}
