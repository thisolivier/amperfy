//
//  DiscoveryTelemetryTest.swift
//  AmperfyKitTests
//
//  Focused tests for the Discovery telemetry recorder's ring-buffer behavior
//  and for the dedicated fast-fail URLSession's timeout configuration
//  (build-60 telemetry sprint).
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

class DiscoveryTelemetryTest: XCTestCase {
  var telemetry: DiscoveryTelemetry!

  override func setUp() {
    telemetry = DiscoveryTelemetry()
  }

  private func beginAndCompleteDeal(trigger: String = "deal") -> String {
    let dealId = telemetry.beginDeal(
      trigger: trigger,
      seedDescription: "recentHistory",
      kindDescription: "album"
    )
    telemetry.completeDeal(
      servedByPool: "sidecar",
      fallbackTaken: false,
      dealtCount: 5,
      totalMs: 42
    )
    return dealId
  }

  // MARK: Deal ring buffer

  func testDealRingBufferCapsAtMaxAndDropsOldest() {
    var dealIds: [String] = []
    for _ in 0 ..< (DiscoveryTelemetry.maxDealRecords + 5) {
      dealIds.append(beginAndCompleteDeal())
    }

    let records = telemetry.dealRecordsNewestFirst()
    XCTAssertEqual(records.count, DiscoveryTelemetry.maxDealRecords)
    XCTAssertEqual(records.first?.dealId, dealIds.last, "newest first")
    XCTAssertEqual(records.last?.dealId, dealIds[5], "the 5 oldest were dropped")
  }

  func testDealIdIsShortHex() {
    let dealId = telemetry.beginDeal(trigger: "deal", seedDescription: "s", kindDescription: "k")
    XCTAssertEqual(dealId.count, 8)
    XCTAssertTrue(dealId.allSatisfy(\.isHexDigit))
  }

  // MARK: Event routing

  func testEventsAppendToOpenDealAndCompleteFinalizesIt() {
    telemetry.beginDeal(trigger: "dealMore", seedDescription: "album(a1)", kindDescription: "album")
    telemetry.appendDealEvent(label: "seed resolution", detail: "songs=3", milliseconds: 7)
    telemetry.appendDealEvent(label: "familiar pool", detail: "ok candidates=9", milliseconds: 120)
    telemetry.completeDeal(
      servedByPool: "sidecar",
      fallbackTaken: false,
      dealtCount: 9,
      totalMs: 150
    )

    let record = telemetry.dealRecordsNewestFirst().first
    XCTAssertEqual(record?.events.count, 2)
    XCTAssertEqual(record?.events.first?.label, "seed resolution")
    XCTAssertEqual(record?.events.last?.milliseconds, 120)
    XCTAssertEqual(record?.servedByPool, "sidecar")
    XCTAssertEqual(record?.dealtCount, 9)
    XCTAssertEqual(record?.totalMs, 150)
    XCTAssertEqual(record?.trigger, "dealMore")
  }

  func testAppendEventWithoutOpenDealIsANoOp() {
    telemetry.appendDealEvent(label: "orphan", detail: "", milliseconds: 1)
    XCTAssertTrue(telemetry.dealRecordsNewestFirst().isEmpty)

    _ = beginAndCompleteDeal()
    telemetry.appendDealEvent(label: "late", detail: "after completion", milliseconds: 1)
    XCTAssertTrue(
      telemetry.dealRecordsNewestFirst().first?.events.isEmpty ?? false,
      "events after completeDeal must not attach to a closed deal"
    )
  }

  func testCurrentDealIdPrefersOpenDealThenFallsBackToNewestCompleted() {
    XCTAssertNil(telemetry.currentDealId)
    let completedId = beginAndCompleteDeal()
    XCTAssertEqual(telemetry.currentDealId, completedId, "sprite fetches after the deal correlate")
    let openId = telemetry.beginDeal(trigger: "deal", seedDescription: "s", kindDescription: "k")
    XCTAssertEqual(telemetry.currentDealId, openId)
  }

  // MARK: Sprite ring buffer

  func testSpriteFetchRingBufferCapsAtMaxAndTagsCurrentDealId() {
    let dealId = beginAndCompleteDeal()
    for index in 0 ..< (DiscoveryTelemetry.maxSpriteFetchRecords + 3) {
      telemetry.recordSpriteFetch(
        urlString: "http://host:8787/sprite-manifest?collectionId=c\(index)",
        outcome: "ready",
        milliseconds: index
      )
    }

    let records = telemetry.spriteFetchRecordsNewestFirst()
    XCTAssertEqual(records.count, DiscoveryTelemetry.maxSpriteFetchRecords)
    XCTAssertEqual(
      records.first?.milliseconds,
      DiscoveryTelemetry.maxSpriteFetchRecords + 2,
      "newest first"
    )
    XCTAssertEqual(records.first?.dealId, dealId)
  }

  // MARK: Dump

  func testPlainTextDumpContainsDealAndSpriteLines() {
    let dealId = beginAndCompleteDeal()
    telemetry.recordSpriteFetch(urlString: "http://h/sprite", outcome: "ready", milliseconds: 12)

    let dump = telemetry.plainTextDump()
    XCTAssertTrue(dump.contains("deal \(dealId)"))
    XCTAssertTrue(dump.contains("served-by=sidecar"))
    XCTAssertTrue(dump.contains("url=http://h/sprite"))
  }

  func testResetClearsEverything() {
    _ = beginAndCompleteDeal()
    telemetry.recordSpriteFetch(urlString: "u", outcome: "ready", milliseconds: 1)
    telemetry.reset()
    XCTAssertTrue(telemetry.dealRecordsNewestFirst().isEmpty)
    XCTAssertTrue(telemetry.spriteFetchRecordsNewestFirst().isEmpty)
    XCTAssertNil(telemetry.currentDealId)
  }

  // MARK: Fast-fail session configuration

  func testFastFailSessionUsesFiveSecondRequestTimeout() {
    let configuration = DiscoveryURLSession.fastFail.configuration
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
  }

  // MARK: Last gateway request status (triage A2)

  func testLastGatewayRequestStatusIsNilWithoutGatewayRecords() {
    XCTAssertNil(telemetry.lastGatewayRequestStatus())
    telemetry.beginDeal(trigger: "deal", seedDescription: "s", kindDescription: "k")
    telemetry.appendDealEvent(
      label: "sidecar request",
      detail: "mode=direct url=http://h/similar-collections status=200",
      milliseconds: 30
    )
    telemetry.recordSpriteFetch(
      urlString: "u",
      outcome: "ready (8 slices) mode=direct",
      milliseconds: 9
    )
    XCTAssertNil(telemetry.lastGatewayRequestStatus(), "direct-mode records don't count")
  }

  func testLastGatewayRequestStatusPicksUpDealEvents() {
    telemetry.beginDeal(trigger: "deal", seedDescription: "s", kindDescription: "k")
    telemetry.appendDealEvent(
      label: "sidecar request",
      detail: "mode=gateway url=http://gw/adjacency/similar-collections status=200",
      milliseconds: 40
    )
    let status = telemetry.lastGatewayRequestStatus()
    XCTAssertEqual(status?.outcome, "200")
    XCTAssertEqual(
      status?.date,
      telemetry.dealRecordsNewestFirst().first?.startedAt,
      "stage events carry no timestamp; the deal's start time stands in"
    )
  }

  func testLastGatewayRequestStatusNewestSpriteFetchWinsOverOlderDeal() {
    telemetry.beginDeal(trigger: "deal", seedDescription: "s", kindDescription: "k")
    telemetry.appendDealEvent(
      label: "sidecar request",
      detail: "mode=gateway url=http://gw/adjacency/similar-collections status=200",
      milliseconds: 40
    )
    // Recorded after the deal began, so its own (later) date wins.
    telemetry.recordSpriteFetch(
      urlString: "http://gw/adjacency/sprite-manifest",
      outcome: "failed (status 401) mode=gateway",
      milliseconds: 15
    )
    XCTAssertEqual(telemetry.lastGatewayRequestStatus()?.outcome, "key rejected (401)")
  }

  func testShortGatewayOutcomeFormats() {
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(from: "mode=gateway url=http://gw/x status=200"),
      "200"
    )
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(from: "mode=gateway url=http://gw/x status=401"),
      "key rejected (401)"
    )
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(from: "failed (status 403) mode=gateway"),
      "key rejected (403)"
    )
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(from: "ready (8 slices) mode=gateway"),
      "200"
    )
    XCTAssertEqual(
      DiscoveryTelemetry
        .shortGatewayOutcome(from: "unavailable (404 not-yet-rendered) mode=gateway"),
      "404 (sprite not rendered yet)"
    )
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(
        from: "mode=gateway url=http://gw/x error=Could not connect to the server."
      ),
      "failed: Could not connect to the server."
    )
    XCTAssertEqual(
      DiscoveryTelemetry.shortGatewayOutcome(from: "failed (The request timed out.) mode=gateway"),
      "failed: The request timed out."
    )
  }
}
