//
//  SubsonicServerApiVersionCoalescingTest.swift
//  AmperfyKitTests
//
//  Created by Claude on 09.07.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import Foundation
import XCTest

// MARK: - PingCountingURLProtocol

/// Intercepts every request that reaches the shared/default URL session and,
/// for `ping.view` requests, counts them and answers with a valid Subsonic ping
/// response after a short delay. The delay guarantees that concurrently-issued
/// version negotiations overlap in time, so a non-coalescing implementation
/// would be caught firing more than one network request.
private final class PingCountingURLProtocol: URLProtocol {
  nonisolated(unsafe) static let pingRequestCount = Atomic<Int>(wrappedValue: 0)

  static let pingResponseBody = """
  <?xml version="1.0" encoding="UTF-8"?>
  <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.13.0">
  </subsonic-response>
  """

  static func reset() {
    pingRequestCount.wrappedValue = 0
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.path.contains("ping") ?? false
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.pingRequestCount.withLock { $0 += 1 }
    // Small delay so concurrent negotiations genuinely overlap in flight.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self else { return }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(Self.pingResponseBody.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

// MARK: - SubsonicServerApiVersionCoalescingTest

@MainActor
class SubsonicServerApiVersionCoalescingTest: XCTestCase {
  var storage: PersistentStorage!
  var eventLogger: EventLogger!
  var performanceMonitor: MOCK_PerformanceMonitor!
  var cdHelper: CoreDataHelper!
  var stubbedConfiguration: URLSessionConfiguration!

  override func setUp() async throws {
    try await super.setUp()
    PingCountingURLProtocol.reset()

    // URLSession configuration whose requests all run through our counting stub
    // protocol. AmperfyKit builds the Alamofire session from this configuration
    // (a globally-registered URLProtocol is not consulted by Alamofire's default
    // session, so the protocol must live on the session's own configuration).
    stubbedConfiguration = URLSessionConfiguration.ephemeral
    stubbedConfiguration.protocolClasses = [PingCountingURLProtocol.self]

    cdHelper = CoreDataHelper()
    _ = cdHelper.createSeededStorage() // loads the in-memory persistent stores
    let mockCoreDataManager = MOCK_CoreDataManager(
      persistentContainer: cdHelper
        .persistentContainer
    )
    storage = PersistentStorage(coreDataManager: mockCoreDataManager)
    eventLogger = EventLogger(storage: storage)
    performanceMonitor = MOCK_PerformanceMonitor()
  }

  private func makeApi() -> SubsonicServerApi {
    let api = SubsonicServerApi(
      performanceMonitor: performanceMonitor,
      eventLogger: eventLogger,
      settings: storage.settings,
      urlSessionConfiguration: stubbedConfiguration
    )
    api.provideCredentials(credentials: LoginCredentials(
      serverUrl: "http://ping-coalesce.local",
      username: "tester",
      password: "secret"
    ))
    return api
  }

  /// Many callers ask for the server API version at the same time. They must
  /// coalesce onto a single in-flight `ping` request instead of each racing its
  /// own (the root cause behind issue #36's empty-body first-search failures).
  func testConcurrentVersionNegotiation_coalescesToSingleNetworkRequest() async throws {
    let api = makeApi()
    let concurrentCallerCount = 12

    let versions = try await withThrowingTaskGroup(of: SubsonicVersion.self) { group in
      for _ in 0 ..< concurrentCallerCount {
        group.addTask {
          try await api._test_getCachedServerApiVersionOrRequestIt()
        }
      }
      var collected = [SubsonicVersion]()
      for try await version in group {
        collected.append(version)
      }
      return collected
    }

    XCTAssertEqual(versions.count, concurrentCallerCount)
    XCTAssertEqual(
      PingCountingURLProtocol.pingRequestCount.wrappedValue,
      1,
      "Concurrent version negotiations must coalesce to a single network ping"
    )
    // All callers must observe the same negotiated version.
    let expectedVersion = SubsonicVersion(major: 1, minor: 13, patch: 0)
    for version in versions {
      XCTAssertEqual(version.description, expectedVersion.description)
    }
  }

  /// After a version has been negotiated once, a subsequent request must use the
  /// cached value and issue no further network ping.
  func testCachedVersion_issuesNoAdditionalNetworkRequest() async throws {
    let api = makeApi()

    _ = try await api._test_getCachedServerApiVersionOrRequestIt()
    XCTAssertEqual(PingCountingURLProtocol.pingRequestCount.wrappedValue, 1)

    _ = try await api._test_getCachedServerApiVersionOrRequestIt()
    XCTAssertEqual(
      PingCountingURLProtocol.pingRequestCount.wrappedValue,
      1,
      "A cached server API version must not trigger another network ping"
    )
  }
}
