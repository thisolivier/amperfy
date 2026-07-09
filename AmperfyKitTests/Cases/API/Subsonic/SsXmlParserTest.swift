//
//  SsXmlParserTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 01.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

class SsXmlParserTest: XCTestCase {
  var xmlData: Data!

  override func setUp() {
    xmlData = getTestFileData(name: "error_example_1")
  }

  override func tearDown() {}

  func testParsing() {
    let parserDelegate = SsPingParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: xmlData)
    parser.delegate = parserDelegate
    parser.parse()

    guard let error = parserDelegate.error else { XCTFail(); return }
    XCTAssertEqual(error.statusCode, 40)
    XCTAssertEqual(error.message, "Wrong username or password")
  }

  // MARK: - Empty response handling (search-parse banner fix)

  /// An empty body can be handed to the parser when a request completes with no payload
  /// (observed on the first search, where concurrent search3 calls race the API-version
  /// negotiation). Such a body must be treated as "effectively empty" so it does not raise
  /// the bogus "XML response could not be parsed." banner.
  func testEffectivelyEmptyResponse_emptyData() {
    XCTAssertTrue(SubsonicLibrarySyncer.isEffectivelyEmptyResponse(Data()))
  }

  func testEffectivelyEmptyResponse_whitespaceOnly() {
    let whitespace = " \n\t\r\n ".data(using: .utf8)!
    XCTAssertTrue(SubsonicLibrarySyncer.isEffectivelyEmptyResponse(whitespace))
  }

  /// A real (even zero-result) Subsonic search3 response is never empty and must still be
  /// parsed normally, so genuine parse failures continue to surface.
  func testEffectivelyEmptyResponse_validEmptySearchResultIsNotEmpty() {
    let emptySearchResult =
      "<subsonic-response xmlns=\"http://subsonic.org/restapi\" status=\"ok\" version=\"1.16.1\">"
        + "<searchResult3></searchResult3></subsonic-response>"
    let data = emptySearchResult.data(using: .utf8)!
    XCTAssertFalse(SubsonicLibrarySyncer.isEffectivelyEmptyResponse(data))
  }

  func testEffectivelyEmptyResponse_populatedResponseIsNotEmpty() {
    XCTAssertFalse(SubsonicLibrarySyncer.isEffectivelyEmptyResponse(xmlData))
  }
}
