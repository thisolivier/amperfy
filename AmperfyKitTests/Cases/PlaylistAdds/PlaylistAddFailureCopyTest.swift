//
//  PlaylistAddFailureCopyTest.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — the loud-failure alert's wording.
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

/// The modal alert is the only thing standing between a refused add and the
/// user believing it worked, so its wording is worth pinning.
final class PlaylistAddFailureCopyTest: XCTestCase {
  private func makeFailure(songCount: Int) -> PlaylistAddPermanentFailure {
    PlaylistAddPermanentFailure(
      playlistName: "My Mix",
      songCount: songCount,
      serverReason: "Playlist is read-only"
    )
  }

  /// One refused song read "The song were NOT added, and have been removed".
  func testSingleSongUsesSingularNounAndVerbs() throws {
    let message = makeFailure(songCount: 1).userFacingMessage

    XCTAssertTrue(message.contains("add 1 song to"), "singular noun in the opening line")
    XCTAssertTrue(
      message.contains("The song was NOT added, and has been removed"),
      "verbs must agree with the singular noun; got:\n\(message)"
    )
    XCTAssertFalse(message.contains("songs"))
    XCTAssertFalse(message.contains("were NOT"))
    XCTAssertFalse(message.contains("have been"))
  }

  /// The plural case keeps reading correctly.
  func testMultipleSongsUsePluralNounAndVerbs() throws {
    let message = makeFailure(songCount: 4).userFacingMessage

    XCTAssertTrue(message.contains("add 4 songs to"))
    XCTAssertTrue(message.contains("The songs were NOT added, and have been removed"))
  }

  /// The user needs the playlist name, the server's reason, and to be told the
  /// local copy was rolled back — all three, or the alert is not actionable.
  func testMessageCarriesPlaylistNameReasonAndRollback() throws {
    let message = makeFailure(songCount: 2).userFacingMessage

    XCTAssertTrue(message.contains("\"My Mix\""))
    XCTAssertTrue(message.contains("Playlist is read-only"))
    XCTAssertTrue(message.contains("removed from the playlist on this device"))
    XCTAssertEqual(makeFailure(songCount: 2).userFacingTitle, "Playlist Not Updated")
  }
}
