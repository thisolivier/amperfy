//
//  AccountServerUrlBackfillTest.swift
//  AmperfyKitTests
//
//  Regression tests for the empty account.serverUrl bug found during the
//  Discovery epic's solo QA round (2026-07-03): accounts created via
//  getAccount(info:) carry only hashes, so account.serverUrl was "" on every
//  install — which silently disabled the Discovery sidecar client and sprite
//  fetcher (both derive their host from account.serverUrl). The fix populates
//  the entity at login and backfills existing accounts on restore.
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

@MainActor
class AccountServerUrlBackfillTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
  }

  private func makeCredentials(
    serverUrl: String = "http://qa-navidrome.example:4534",
    username: String = "amperfy-qa"
  )
    -> LoginCredentials {
    var credentials = LoginCredentials(
      serverUrl: serverUrl,
      username: username,
      password: "secret"
    )
    credentials.backendApi = .subsonic
    return credentials
  }

  /// Documents the trap this fix addresses: an account created from an
  /// AccountInfo (hashes only) has an empty serverUrl.
  func testAccountCreatedFromInfoHasEmptyServerUrl() {
    let account = library.getAccount(info: TestAccountInfo.create1())
    XCTAssertEqual(account.serverUrl, "")
    XCTAssertEqual(account.userName, "")
  }

  func testBackfillPopulatesServerUrlAndUserName() {
    let account = library.getAccount(info: TestAccountInfo.create1())
    let credentials = makeCredentials()

    let didBackfill = account.backfillIdentityIfMissing(from: credentials)

    XCTAssertTrue(didBackfill)
    XCTAssertEqual(account.serverUrl, "http://qa-navidrome.example:4534")
    XCTAssertEqual(account.userName, "amperfy-qa")
  }

  func testBackfillLeavesPopulatedAccountUntouched() {
    let account = library.getAccount(info: TestAccountInfo.create1())
    account.backfillIdentityIfMissing(from: makeCredentials())

    let didBackfillAgain = account.backfillIdentityIfMissing(
      from: makeCredentials(serverUrl: "http://other.example", username: "someone-else")
    )

    XCTAssertFalse(didBackfillAgain)
    XCTAssertEqual(account.serverUrl, "http://qa-navidrome.example:4534")
    XCTAssertEqual(account.userName, "amperfy-qa")
  }
}
