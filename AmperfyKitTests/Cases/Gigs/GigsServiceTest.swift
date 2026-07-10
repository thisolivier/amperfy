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

  func testParsesAllEventsFromFixture() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    XCTAssertEqual(events.count, 3)
  }

  func testParsesEventFieldsCorrectly() throws {
    let events = try GigsService.parseEvents(from: fixtureData())
    // Sorted date-ascending: evt-002 (Aug 2) is first.
    let first = events[0]
    XCTAssertEqual(first.id, "evt-002")
    XCTAssertEqual(first.artistName, "Goose")
    XCTAssertEqual(first.venueName, "The Roundhouse")
    XCTAssertEqual(first.city, "London")
    XCTAssertEqual(first.source, "skiddle")
    XCTAssertEqual(first.countryCode, "GB")
    XCTAssertNotNil(first.ticketURL)
    XCTAssertEqual(first.ticketURL?.absoluteString, "https://skiddle.example.com/evt-002")
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

  func testDecodingFailureThrows() {
    let garbage = Data("not json".utf8)
    XCTAssertThrowsError(try GigsService.parseEvents(from: garbage)) { error in
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
    XCTAssertEqual(sections.count, 3)
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
