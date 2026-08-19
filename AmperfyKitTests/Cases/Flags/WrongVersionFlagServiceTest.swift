//
//  WrongVersionFlagServiceTest.swift
//  AmperfyKitTests
//
//  Request-building and payload-encoding tests for the wrong-version flag
//  client (docs/WRONG_VERSION_FLAGS_SPEC.md, Build 1). No live server is
//  involved: a URLProtocol stub captures the request the way
//  AdjacencySidecarClientTest does, and the pure encode/URL helpers are
//  asserted directly.
//
//  Note on the captured body: URLSession moves `httpBody` into
//  `httpBodyStream` before the protocol sees the request, so the assertions
//  read the stream back rather than `httpBody` (which is always nil here).
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

// MARK: - FlagStubURLProtocol

private final class FlagStubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var statusCode = 201
  nonisolated(unsafe) static var connectionError: Error?
  nonisolated(unsafe) static var capturedRequest: URLRequest?
  nonisolated(unsafe) static var capturedBody: Data?

  static func reset() {
    statusCode = 201
    connectionError = nil
    capturedRequest = nil
    capturedBody = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.capturedRequest = request
    Self.capturedBody = request.httpBody ?? Self.readBodyStream(of: request)
    if let connectionError = Self.connectionError {
      client?.urlProtocol(self, didFailWithError: connectionError)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: Self.statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// URLSession hands the protocol a stream, not `httpBody`.
  private static func readBodyStream(of request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let readCount = stream.read(&buffer, maxLength: bufferSize)
      if readCount <= 0 { break }
      data.append(buffer, count: readCount)
    }
    return data
  }
}

// MARK: - WrongVersionFlagServiceTest

class WrongVersionFlagServiceTest: XCTestCase {
  private var session: URLSession!
  private var gatewaySettings: AdjacencyGatewaySettings!

  override func setUp() {
    super.setUp()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FlagStubURLProtocol.self]
    session = URLSession(configuration: configuration)
    gatewaySettings = AdjacencyGatewaySettings(
      defaults: UserDefaults(suiteName: "WrongVersionFlagServiceTest-\(UUID().uuidString)")!
    )
    FlagStubURLProtocol.reset()
  }

  override func tearDown() {
    FlagStubURLProtocol.reset()
    super.tearDown()
  }

  private func configureGateway(urlString: String = "http://gateway.local:5041") {
    gatewaySettings.gatewayUrlString = urlString
    gatewaySettings.gatewayApiKey = "test-key"
  }

  private func makeService() -> WrongVersionFlagService {
    WrongVersionFlagService(gatewaySettings: gatewaySettings, session: session)
  }

  private func samplePayload(note: String? = "wrong mix") -> WrongVersionFlagPayload {
    WrongVersionFlagPayload(
      songId: "song-42",
      title: "Praise You",
      artist: "Fatboy Slim",
      album: "You've Come a Long Way, Baby",
      note: note,
      contextName: "Playlist: Big Beat",
      appVersion: "1.9.2",
      buildNumber: "85"
    )
  }

  private func capturedBodyObject() throws -> [String: Any] {
    let body = try XCTUnwrap(FlagStubURLProtocol.capturedBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  // MARK: - URL building

  func testGatewayURLUsesNaviPrefixAndFlagsPath() throws {
    let route = try XCTUnwrap(AdjacencyGatewayRoute.make(
      urlString: "http://gateway.local:5041",
      apiKey: "k"
    ))
    let url = try XCTUnwrap(WrongVersionFlagService.gatewayURL(route: route))
    XCTAssertEqual(url.absoluteString, "http://gateway.local:5041/navi/api/v1/flags")
  }

  func testGatewayURLKeepsBasePathAndDropsTrailingSlash() throws {
    let route = try XCTUnwrap(AdjacencyGatewayRoute.make(
      urlString: "https://example.com/edge/",
      apiKey: "k"
    ))
    let url = try XCTUnwrap(WrongVersionFlagService.gatewayURL(route: route))
    XCTAssertEqual(url.absoluteString, "https://example.com/edge/navi/api/v1/flags")
  }

  func testPathPrefixMatchesSpec() {
    XCTAssertEqual(WrongVersionFlagService.gatewaySidecarPathPrefix, "/navi")
    XCTAssertEqual(WrongVersionFlagService.flagsPath, "/api/v1/flags")
  }

  // MARK: - Request shape

  func testSubmitSendsPostToGatewayWithApiKeyAndJsonContentType() async throws {
    configureGateway()
    try await makeService().submitFlag(samplePayload())

    let request = try XCTUnwrap(FlagStubURLProtocol.capturedRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "http://gateway.local:5041/navi/api/v1/flags")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: AdjacencyGatewayRoute.apiKeyHeaderName),
      "test-key"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testSubmitBodyCarriesAllPayloadFieldsInCamelCase() async throws {
    configureGateway()
    try await makeService().submitFlag(samplePayload())

    let object = try capturedBodyObject()
    XCTAssertEqual(object["songId"] as? String, "song-42")
    XCTAssertEqual(object["title"] as? String, "Praise You")
    XCTAssertEqual(object["artist"] as? String, "Fatboy Slim")
    XCTAssertEqual(object["album"] as? String, "You've Come a Long Way, Baby")
    XCTAssertEqual(object["note"] as? String, "wrong mix")
    XCTAssertEqual(object["contextName"] as? String, "Playlist: Big Beat")
    XCTAssertEqual(object["appVersion"] as? String, "1.9.2")
    XCTAssertEqual(object["buildNumber"] as? String, "85")
  }

  // MARK: - Payload encoding

  func testNilOptionalFieldsAreOmittedNotNull() throws {
    let payload = WrongVersionFlagPayload(
      songId: "song-1",
      title: nil,
      artist: nil,
      album: nil,
      note: nil,
      contextName: nil,
      appVersion: nil,
      buildNumber: nil
    )
    let data = try WrongVersionFlagService.encode(payload: payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object.count, 1)
    XCTAssertEqual(object["songId"] as? String, "song-1")
    XCTAssertNil(object["note"])
    XCTAssertNil(object["title"])
  }

  func testEncodedPayloadRoundTrips() throws {
    let payload = samplePayload()
    let data = try WrongVersionFlagService.encode(payload: payload)
    let decoded = try JSONDecoder().decode(WrongVersionFlagPayload.self, from: data)
    XCTAssertEqual(decoded, payload)
  }

  func testEmptyNoteIsRepresentableAsNil() throws {
    // The dialog maps a blank note to nil; the encoder must then omit it.
    let payload = samplePayload(note: nil)
    let data = try WrongVersionFlagService.encode(payload: payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(object["note"])
    XCTAssertEqual(object["songId"] as? String, "song-42")
  }

  // MARK: - Failure modes

  func testSubmitThrowsNotConfiguredWithoutGateway() async {
    XCTAssertFalse(makeService().isConfigured)
    do {
      try await makeService().submitFlag(samplePayload())
      XCTFail("Expected .notConfigured to be thrown")
    } catch {
      XCTAssertEqual(error as? WrongVersionFlagError, .notConfigured)
    }
    XCTAssertNil(FlagStubURLProtocol.capturedRequest)
  }

  func testSubmitThrowsNotConfiguredWhenOnlyUrlIsSet() async {
    gatewaySettings.gatewayUrlString = "http://gateway.local:5041"
    do {
      try await makeService().submitFlag(samplePayload())
      XCTFail("Expected .notConfigured to be thrown")
    } catch {
      XCTAssertEqual(error as? WrongVersionFlagError, .notConfigured)
    }
  }

  func testNonSuccessStatusThrowsBadResponse() async throws {
    configureGateway()
    FlagStubURLProtocol.statusCode = 401
    do {
      try await makeService().submitFlag(samplePayload())
      XCTFail("Expected .badResponse to be thrown")
    } catch {
      XCTAssertEqual(error as? WrongVersionFlagError, .badResponse(statusCode: 401))
    }
  }

  func testTransportFailureThrowsUnreachable() async throws {
    configureGateway()
    FlagStubURLProtocol.connectionError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCannotConnectToHost
    )
    do {
      try await makeService().submitFlag(samplePayload())
      XCTFail("Expected .unreachable to be thrown")
    } catch {
      XCTAssertEqual(error as? WrongVersionFlagError, .unreachable)
    }
  }

  func testEveryErrorHasUserFacingDescription() {
    let errors: [WrongVersionFlagError] = [
      .notConfigured,
      .unreachable,
      .badResponse(statusCode: 500),
      .encodingFailed,
    ]
    for error in errors {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    XCTAssertTrue(
      WrongVersionFlagError.notConfigured.localizedDescription.contains("Gateway not configured")
    )
  }

  // MARK: - Bundle metadata

  func testBundleMetadataReadsInfoDictionaryKeys() {
    // The test bundle carries both keys, so this asserts the accessor wiring
    // rather than any particular version string.
    let bundle = Bundle(for: type(of: self))
    XCTAssertEqual(
      WrongVersionFlagService.bundleAppVersion(bundle),
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    )
    XCTAssertEqual(
      WrongVersionFlagService.bundleBuildNumber(bundle),
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
  }
}
