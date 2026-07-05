//
//  AdjacencyGatewayRouteTest.swift
//  AmperfyKitTests
//
//  Tests for the gateway-vs-direct mode decision (BOTH URL and key required),
//  `{gatewayURL}/adjacency{path}` URL building, sprite-URL rebasing, and the
//  connection test's 401 "key rejected" classification.
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

class AdjacencyGatewayRouteTest: XCTestCase {
  var settings: AdjacencyGatewaySettings!

  override func setUp() {
    settings = AdjacencyGatewaySettings(
      defaults: UserDefaults(suiteName: "AdjacencyGatewayRouteTest-\(UUID().uuidString)")!
    )
  }

  // MARK: - Mode decision (BOTH url and key required)

  func testNoRouteWhenNothingIsSet() {
    XCTAssertNil(settings.activeRoute)
  }

  func testNoRouteWhenOnlyUrlIsSet() {
    settings.gatewayUrlString = "http://localhost:5041"
    XCTAssertNil(settings.activeRoute)
  }

  func testNoRouteWhenOnlyKeyIsSet() {
    settings.gatewayApiKey = "secret-key"
    XCTAssertNil(settings.activeRoute)
  }

  func testNoRouteWhenValuesAreOnlyWhitespace() {
    settings.gatewayUrlString = "   "
    settings.gatewayApiKey = "\n"
    XCTAssertNil(settings.activeRoute)
  }

  func testNoRouteWhenUrlIsNotAUsableAbsoluteURL() {
    settings.gatewayUrlString = "not a url"
    settings.gatewayApiKey = "secret-key"
    XCTAssertNil(settings.activeRoute)
  }

  func testRouteActiveWhenBothAreSetAndValuesAreTrimmed() throws {
    settings.gatewayUrlString = " http://localhost:5041 "
    settings.gatewayApiKey = " secret-key\n"
    let route = try XCTUnwrap(settings.activeRoute)
    XCTAssertEqual(route.baseURL.absoluteString, "http://localhost:5041")
    XCTAssertEqual(route.apiKey, "secret-key")
    XCTAssertEqual(route.httpHeaderFields, ["X-API-Key": "secret-key"])
  }

  // MARK: - Gateway URL building

  private func makeRoute(urlString: String = "http://localhost:5041")
    -> AdjacencyGatewayRoute {
    AdjacencyGatewayRoute.make(urlString: urlString, apiKey: "secret-key")!
  }

  func testBuildsGatewayPrefixedURLWithQueryItems() {
    let url = makeRoute().url(
      sidecarPath: "/similar-collections",
      queryItems: [URLQueryItem(name: "collectionId", value: "album-1")]
    )
    XCTAssertEqual(
      url?.absoluteString,
      "http://localhost:5041/adjacency/similar-collections?collectionId=album-1"
    )
  }

  func testBuildsGatewayHealthURLWithoutQueryItems() {
    XCTAssertEqual(
      makeRoute().url(sidecarPath: "/health")?.absoluteString,
      "http://localhost:5041/adjacency/health"
    )
  }

  func testTrailingSlashOnGatewayURLDoesNotDoubleTheSlash() {
    XCTAssertEqual(
      makeRoute(urlString: "http://localhost:5041/").url(sidecarPath: "/health")?.absoluteString,
      "http://localhost:5041/adjacency/health"
    )
  }

  // MARK: - Sprite-URL rebasing (gateway sprite-audio path)

  func testRebasesServerRelativeSpriteURLThroughGateway() throws {
    let spriteURL = try XCTUnwrap(URL(string: "/sprite-audio?collectionId=al-1&kind=album"))
    XCTAssertEqual(
      makeRoute().url(rebasing: spriteURL)?.absoluteString,
      "http://localhost:5041/adjacency/sprite-audio?collectionId=al-1&kind=album"
    )
  }

  func testRebasesAbsoluteSpriteURLThroughGatewayKeepingPathAndQuery() throws {
    let spriteURL = try XCTUnwrap(
      URL(string: "http://navidrome.local:8787/sprite-audio?collectionId=al-1")
    )
    XCTAssertEqual(
      makeRoute().url(rebasing: spriteURL)?.absoluteString,
      "http://localhost:5041/adjacency/sprite-audio?collectionId=al-1"
    )
  }

  // MARK: - Connection-test classification

  func testGateway401IsClassifiedAsKeyRejected() {
    let text = AdjacencyConnectionTest.resultText(
      urlString: "http://localhost:5041/adjacency/health",
      statusCode: 401,
      latencyMilliseconds: 12,
      mode: .gateway
    )
    XCTAssertTrue(text.contains("key rejected"), "got: \(text)")
    XCTAssertTrue(text.contains("401"))
  }

  func testGatewayNon401IsAGenericResultWithModeAndStatus() {
    let text = AdjacencyConnectionTest.resultText(
      urlString: "http://localhost:5041/adjacency/health",
      statusCode: 200,
      latencyMilliseconds: 12,
      mode: .gateway
    )
    XCTAssertFalse(text.contains("key rejected"))
    XCTAssertTrue(text.contains("Mode: gateway"))
    XCTAssertTrue(text.contains("HTTP 200"))
  }

  func testDirect401IsNotClassifiedAsKeyRejected() {
    let text = AdjacencyConnectionTest.resultText(
      urlString: "http://navidrome.local:8787/health",
      statusCode: 401,
      latencyMilliseconds: 12,
      mode: .direct
    )
    XCTAssertFalse(text.contains("key rejected"))
    XCTAssertTrue(text.contains("Mode: direct"))
  }
}
