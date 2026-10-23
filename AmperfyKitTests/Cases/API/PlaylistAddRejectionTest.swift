//
//  PlaylistAddRejectionTest.swift
//  AmperfyKitTests
//
//  Created by Olivier Butler on 23.10.26.
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

// MARK: - PlaylistAddRejectionCopyTest

/// The alert is the only thing standing between a refused add and the user
/// believing it worked, so its wording is worth pinning.
final class PlaylistAddRejectionCopyTest: XCTestCase {
  private func createRejection(songCount: Int) -> PlaylistAddRejection {
    PlaylistAddRejection(
      playlistName: "My Mix",
      songCount: songCount,
      serverReason: "Playlist is read-only"
    )
  }

  /// A single refused song used to read "The song were not added".
  func testSingleSongUsesSingularNounAndVerb() throws {
    let message = createRejection(songCount: 1).userFacingMessage

    XCTAssertTrue(message.contains("add 1 song to"), "singular noun in the opening line")
    XCTAssertTrue(
      message.contains("The song was not added"),
      "verb must agree with the singular noun; got:\n\(message)"
    )
    XCTAssertFalse(message.contains("songs"))
    XCTAssertFalse(message.contains("were not"))
  }

  func testMultipleSongsUsePluralNounAndVerb() throws {
    let message = createRejection(songCount: 4).userFacingMessage

    XCTAssertTrue(message.contains("add 4 songs to"))
    XCTAssertTrue(message.contains("The songs were not added"))
  }

  /// The playlist name, the server's reason and the state of the local copy —
  /// all three, or the alert is not actionable.
  func testMessageCarriesPlaylistNameReasonAndLocalState() throws {
    let rejection = createRejection(songCount: 2)

    XCTAssertEqual(rejection.userFacingTitle, "Playlist Not Updated")
    XCTAssertTrue(rejection.userFacingMessage.contains("\"My Mix\""))
    XCTAssertTrue(rejection.userFacingMessage.contains("Playlist is read-only"))
    XCTAssertTrue(
      rejection.userFacingMessage.contains("your local copy of the playlist is unchanged")
    )
  }
}

// MARK: - PlaylistAddRejectionClassificationTest

/// Only failures a retry can never fix may interrupt the user with a modal.
/// Everything else has to stay a notification banner.
final class PlaylistAddRejectionClassificationTest: XCTestCase {
  private func createApiError(statusCode: Int, message: String = "") -> ResponseError {
    ResponseError(type: .api, statusCode: statusCode, message: message)
  }

  private func createRejection(for error: Error) -> PlaylistAddRejection? {
    PlaylistAddRejection(error: error, playlistName: "My Mix", songCount: 3)
  }

  // MARK: Rejections

  /// Subsonic 50 — what Navidrome answers for a playlist it owns.
  func testSubsonicUserIsNotAuthorizedIsARejection() throws {
    let rejection = try XCTUnwrap(createRejection(for: createApiError(statusCode: 50)))
    XCTAssertTrue(rejection.serverReason.contains("error 50"))
    XCTAssertEqual(rejection.playlistName, "My Mix")
    XCTAssertEqual(rejection.songCount, 3)
  }

  /// Subsonic 70 — the playlist is gone, so there is nothing to retry against.
  func testSubsonicRequestedDataNotFoundIsARejection() throws {
    let rejection = try XCTUnwrap(createRejection(for: createApiError(statusCode: 70)))
    XCTAssertTrue(rejection.serverReason.contains("error 70"))
  }

  func testAmpacheAccessDeniedIsARejection() throws {
    XCTAssertNotNil(createRejection(for: createApiError(statusCode: 4703)))
  }

  func testAmpacheFailedAccessCheckIsARejection() throws {
    XCTAssertNotNil(createRejection(for: createApiError(statusCode: 4742)))
  }

  func testAmpacheNotFoundIsARejection() throws {
    XCTAssertNotNil(createRejection(for: createApiError(statusCode: 4704)))
  }

  /// The server's own words beat our canned text whenever it sent any.
  func testServerMessageIsPreferredOverTheFallbackReason() throws {
    let rejection = try XCTUnwrap(createRejection(for: createApiError(
      statusCode: 50,
      message: "Playlist is synchronized and cannot be modified"
    )))
    XCTAssertEqual(rejection.serverReason, "Playlist is synchronized and cannot be modified")
  }

  func testBlankServerMessageFallsBackToACannedReason() throws {
    let rejection = try XCTUnwrap(createRejection(for: createApiError(
      statusCode: 50,
      message: "   \n "
    )))
    XCTAssertFalse(rejection.serverReason.isEmpty)
    XCTAssertTrue(rejection.serverReason.contains("not accepting changes"))
  }

  // MARK: Transient failures

  /// A generic API error says nothing about whether a retry would work.
  func testGenericApiErrorIsTransient() throws {
    XCTAssertNil(createRejection(for: createApiError(statusCode: 0)))
  }

  func testServerSideApiErrorIsTransient() throws {
    XCTAssertNil(createRejection(for: createApiError(statusCode: 500)))
  }

  /// Wrong credentials are the login flow's problem, not this alert's.
  func testWrongCredentialsIsTransient() throws {
    XCTAssertNil(createRejection(for: createApiError(statusCode: 40)))
  }

  /// An unparseable body is a bad reply, not a refusal.
  func testXmlParseErrorIsTransient() throws {
    XCTAssertNil(createRejection(for: ResponseError(type: .xml, statusCode: 50)))
  }

  /// A resource error carries an unrelated status code space.
  func testResourceErrorIsTransient() throws {
    XCTAssertNil(createRejection(for: ResponseError(type: .resource, statusCode: 50)))
  }

  func testNetworkErrorIsTransient() throws {
    XCTAssertNil(createRejection(for: URLError(.notConnectedToInternet)))
  }

  /// Raised while a freshly created playlist has no server id yet; the add is
  /// still worth another go.
  func testIncorrectServerBehaviorIsTransient() throws {
    XCTAssertNil(
      createRejection(for: BackendError.incorrectServerBehavior(message: "no playlist id"))
    )
  }
}
