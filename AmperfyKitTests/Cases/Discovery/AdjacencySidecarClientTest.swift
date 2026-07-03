//
//  AdjacencySidecarClientTest.swift
//  AmperfyKitTests
//
//  Tests for AdjacencySidecarClient's URL construction, response decoding,
//  and error mapping (Discovery sprint D4). Stubs the network via a custom
//  URLProtocol so no real adjacency-sidecar is needed.
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

// MARK: - StubURLProtocol

private final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data?))?
  /// When set, `startLoading` reports this as a transport-level failure
  /// (connection refused / timeout / etc.) instead of running `handler` —
  /// this is what a genuinely-unreachable server looks like at the
  /// `URLSession` layer, distinct from a reachable server answering with a
  /// non-2xx status code.
  nonisolated(unsafe) static var connectionError: Error?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if let connectionError = Self.connectionError {
      client?.urlProtocol(self, didFailWithError: connectionError)
      return
    }
    let (statusCode, data) = Self.handler?(request) ?? (200, Data())
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let data { client?.urlProtocol(self, didLoad: data) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

// MARK: - AdjacencySidecarClientTest

class AdjacencySidecarClientTest: XCTestCase {
  var session: URLSession!
  var settings: AdjacencySidecarSettings!
  var lastRequest: URLRequest?

  override func setUp() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    session = URLSession(configuration: configuration)
    settings = AdjacencySidecarSettings(
      defaults: UserDefaults(suiteName: "AdjacencySidecarClientTest-\(UUID().uuidString)")!
    )
    lastRequest = nil
    StubURLProtocol.connectionError = nil
  }

  private func makeClient(serverUrl: String = "http://navidrome.local:4533")
    -> AdjacencySidecarClient {
    AdjacencySidecarClient(serverUrl: serverUrl, settings: settings, session: session)
  }

  private func stub(statusCode: Int, body: String?) {
    StubURLProtocol.handler = { [weak self] request in
      self?.lastRequest = request
      return (statusCode, body?.data(using: .utf8))
    }
  }

  private func stubConnectionFailure() {
    StubURLProtocol.connectionError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCannotConnectToHost
    )
  }

  // MARK: - URL construction

  func testSeedCollectionRoutesToSimilarCollectionsWithPortSubstituted() async throws {
    settings.port = 8788
    stub(statusCode: 200, body: "[]")

    _ = try await makeClient().fetchCandidates(
      seedSongIds: [],
      seedCollection: (id: "album-1", kind: .album),
      kind: .album,
      count: 10
    )

    let url = try XCTUnwrap(lastRequest?.url)
    XCTAssertEqual(url.host, "navidrome.local")
    XCTAssertEqual(url.port, 8788)
    XCTAssertEqual(url.path, "/similar-collections")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let itemsByName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    XCTAssertEqual(itemsByName["collectionId"], "album-1")
    XCTAssertEqual(itemsByName["kind"], "album")
    XCTAssertEqual(itemsByName["count"], "10")
  }

  func testHistorySeedRoutesToSimilarFromHistoryWithJoinedIds() async throws {
    stub(statusCode: 200, body: "[]")

    _ = try await makeClient().fetchCandidates(
      seedSongIds: ["s1", "s2", "s3"],
      seedCollection: nil,
      kind: .playlist,
      count: 5
    )

    let url = try XCTUnwrap(lastRequest?.url)
    XCTAssertEqual(url.path, "/similar-from-history")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let itemsByName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    XCTAssertEqual(itemsByName["seedSongIds"], "s1,s2,s3")
    XCTAssertEqual(itemsByName["kind"], "playlist")
  }

  // MARK: - Decoding

  func testDecodesSuccessfulResponse() async throws {
    stub(
      statusCode: 200,
      body: """
      [{"collectionId":"al-1","kind":"album","score":0.87,"evidence":{"sharedTracks":4}}]
      """
    )

    let results = try await makeClient().fetchCandidates(
      seedSongIds: [],
      seedCollection: (id: "seed", kind: .album),
      kind: .album,
      count: 10
    )

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].collectionId, "al-1")
    XCTAssertEqual(results[0].kind, .album)
    XCTAssertEqual(results[0].score, 0.87, accuracy: 0.001)
    XCTAssertEqual(results[0].seedTitle, "", "client never knows the human-readable seed title")
  }

  func testEmptyArrayIsALegitimateEmptyResultNotAnError() async throws {
    stub(statusCode: 200, body: "[]")

    let results = try await makeClient().fetchCandidates(
      seedSongIds: [],
      seedCollection: (id: "seed", kind: .album),
      kind: .album,
      count: 10
    )

    XCTAssertTrue(results.isEmpty)
  }

  // MARK: - Errors

  func testNon2xxThrowsUnreachable() async {
    stub(statusCode: 500, body: nil)

    await XCTAssertThrowsErrorAsync(
      try await makeClient().fetchCandidates(
        seedSongIds: [],
        seedCollection: (id: "seed", kind: .album),
        kind: .album,
        count: 10
      )
    ) { error in
      XCTAssertEqual(error as? DeckPoolError, .unreachable)
    }
  }

  /// `/similar-collections` and `/similar-from-history` never 404 for a
  /// legitimate zero-match seed — confirmed by reading the real
  /// adjacency-sidecar source (`server.py`'s `_handle_similar_collections`/
  /// `_handle_similar_from_history` always call `_send_json(...)` with the
  /// default `status=200`, even when the underlying query returns an empty
  /// list; 404 is reserved for entirely unrecognized routes). So a 404
  /// actually observed here means the request hit the wrong path/host
  /// entirely (routing/config bug), not "no matches" — `.unreachable` is
  /// the correct classification, matching the doc comment on
  /// `AdjacencySidecarClient.fetchCandidates`.
  func testNotFoundThrowsUnreachable() async {
    stub(statusCode: 404, body: #"{"error":"Not found"}"#)

    await XCTAssertThrowsErrorAsync(
      try await makeClient().fetchCandidates(
        seedSongIds: [],
        seedCollection: (id: "seed", kind: .album),
        kind: .album,
        count: 10
      )
    ) { error in
      XCTAssertEqual(error as? DeckPoolError, .unreachable)
    }
  }

  /// A genuine transport failure (connection refused, timeout, DNS
  /// failure, ...) — the case the "unreachable" pool-degraded state is
  /// actually meant to represent, as distinct from a reachable server
  /// answering with a non-2xx status.
  func testConnectionFailureThrowsUnreachable() async {
    stubConnectionFailure()

    await XCTAssertThrowsErrorAsync(
      try await makeClient().fetchCandidates(
        seedSongIds: [],
        seedCollection: (id: "seed", kind: .album),
        kind: .album,
        count: 10
      )
    ) { error in
      XCTAssertEqual(error as? DeckPoolError, .unreachable)
    }
  }

  func testMalformedJSONThrowsDecodingFailed() async {
    stub(statusCode: 200, body: "not json")

    await XCTAssertThrowsErrorAsync(
      try await makeClient().fetchCandidates(
        seedSongIds: [],
        seedCollection: (id: "seed", kind: .album),
        kind: .album,
        count: 10
      )
    ) { error in
      XCTAssertEqual(error as? DeckPoolError, .decodingFailed)
    }
  }

  func testUnparsableServerUrlThrowsUnreachable() async {
    await XCTAssertThrowsErrorAsync(
      try await makeClient(serverUrl: "not-a-url").fetchCandidates(
        seedSongIds: ["s1"],
        seedCollection: nil,
        kind: .album,
        count: 10
      )
    ) { error in
      XCTAssertEqual(error as? DeckPoolError, .unreachable)
    }
  }
}

// MARK: - XCTAssertThrowsErrorAsync

private func XCTAssertThrowsErrorAsync<T: Sendable>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ errorHandler: (Error) -> () = { _ in }
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error to be thrown", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
