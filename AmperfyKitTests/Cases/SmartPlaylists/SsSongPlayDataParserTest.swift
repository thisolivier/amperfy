//
//  SsSongPlayDataParserTest.swift
//  AmperfyKitTests
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
import CoreData
import XCTest

/// Covers the two `SsSongParserDelegate` changes Smart Playlists depend on:
///
///  1. **Tolerant RFC3339 parsing.** `ISO8601DateFormatter` treats
///     `.withFractionalSeconds` as REQUIRED, and Go's RFC3339 marshalling (our
///     Navidrome fork) omits trailing-zero fractions — so `created` values
///     mostly used to parse to `nil`, which is why `addedDate` was so sparse.
///  2. **Server play-data merge.** `playCount` / `played` are folded into the
///     existing local fields as `max` / `later`, never overwritten, so an
///     offline play stays visible immediately and a later sync can only raise
///     the floor with plays from other clients.
@MainActor
class SsSongPlayDataParserTest: XCTestCase {
  var context: NSManagedObjectContext!
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    context = coreDataHelper.createInMemoryManagedObjectContext()
    coreDataHelper.clearContext(context: context)
    library = LibraryStorage(context: context)
    account = library.getAccount(info: TestAccountInfo.create1())
  }

  override func tearDown() {}

  // MARK: - Helpers

  /// Builds a one-song `getAlbum`-shaped response with the given extra song
  /// attributes. Inline rather than a sample file so the fixture sits next to
  /// the assertions it serves (and needs no pbxproj resource entry).
  private func makeResponse(songAttributes: String) -> Data {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1">
      <album id="spd-album" name="Play Data" songCount="1" artist="Tester" artistId="spd-artist">
        <song id="spd-song" title="Merge Me" album="Play Data" artist="Tester" \
    albumId="spd-album" artistId="spd-artist" isDir="false" duration="180" size="4096" \
    suffix="mp3" contentType="audio/mpeg" type="music" \(songAttributes)/>
      </album>
    </subsonic-response>
    """
    return Data(xml.utf8)
  }

  /// Runs the id pre-pass and the song parser over the response, exactly as
  /// `SubsonicLibrarySyncer` does.
  private func parse(_ data: Data) {
    let idParserDelegate = SsIDsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let idParser = XMLParser(data: data)
    idParser.delegate = idParserDelegate
    idParser.parse()
    XCTAssertNil(idParserDelegate.error)

    let prefetch = library.getElements(
      account: account,
      prefetchIDs: idParserDelegate.prefetchIDs
    )
    let songParserDelegate = SsSongParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor(),
      prefetch: prefetch,
      account: account,
      library: library,
      parseNotifier: nil
    )
    let parser = XMLParser(data: data)
    parser.delegate = songParserDelegate
    parser.parse()
    XCTAssertNil(songParserDelegate.error)
    library.saveContext()
  }

  private var parsedSong: Song? {
    library.getSongs(for: account).first { $0.id == "spd-song" }
  }

  /// Pre-creates the song with local play state, as if the user had played it
  /// on this device before the sync ran.
  @discardableResult
  private func makeLocallyPlayedSong(playCount: Int, lastPlayedDate: Date?) -> Song {
    let song = library.createSong(account: account)
    song.id = "spd-song"
    song.title = "Merge Me"
    song.size = 4096
    song.playCount = playCount
    song.lastTimePlayed = lastPlayedDate
    library.saveContext()
    return song
  }

  private func date(_ rawValue: String) -> Date {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return dateFormatter.date(from: rawValue)
      ?? {
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: rawValue)!
      }()
  }

  // MARK: - Tolerant date parsing

  /// The regression this whole fix exists for: Go emits `...:00Z` with no
  /// fraction, and the fractional-seconds-only formatter returned nil, leaving
  /// `addedDate` empty across the library.
  func testCreatedWithoutFractionalSecondsIsParsed() {
    parse(makeResponse(songAttributes: #"created="2026-08-01T10:00:00Z""#))
    XCTAssertEqual(parsedSong?.addedDate, date("2026-08-01T10:00:00Z"))
  }

  /// The stricter format still works — the fallback added tolerance, it did not
  /// trade one format for another.
  func testCreatedWithFractionalSecondsIsStillParsed() {
    parse(makeResponse(songAttributes: #"created="2026-08-01T10:00:00.123456789Z""#))
    XCTAssertEqual(parsedSong?.addedDate, date("2026-08-01T10:00:00.123456789Z"))
  }

  /// Genuinely unparseable values stay nil rather than becoming a bogus date.
  func testUnparseableCreatedStaysNil() {
    parse(makeResponse(songAttributes: #"created="not-a-date""#))
    XCTAssertNil(parsedSong?.addedDate)
  }

  func testParseServerDateAcceptsBothFormsAndRejectsGarbage() {
    XCTAssertNotNil(SsSongParserDelegate.parseServerDate("2026-08-01T10:00:00Z"))
    XCTAssertNotNil(SsSongParserDelegate.parseServerDate("2026-08-01T10:00:00.5Z"))
    XCTAssertNotNil(SsSongParserDelegate.parseServerDate("2026-08-01T10:00:00+02:00"))
    XCTAssertNil(SsSongParserDelegate.parseServerDate(""))
    XCTAssertNil(SsSongParserDelegate.parseServerDate("2026-08-01"))
  }

  // MARK: - playCount merge

  func testServerPlayCountIsAdoptedWhenNoLocalPlaysExist() {
    parse(makeResponse(songAttributes: #"playCount="7""#))
    XCTAssertEqual(parsedSong?.playCount, 7)
  }

  /// A higher server count wins: those are plays from other clients that the
  /// device never saw.
  func testHigherServerPlayCountRaisesTheLocalFloor() {
    makeLocallyPlayedSong(playCount: 2, lastPlayedDate: nil)
    parse(makeResponse(songAttributes: #"playCount="9""#))
    XCTAssertEqual(parsedSong?.playCount, 9)
  }

  /// A lower server count must NOT clobber local plays — the offline plays the
  /// user just made on the bus have not been scrobbled yet.
  func testLowerServerPlayCountDoesNotClobberLocalPlays() {
    makeLocallyPlayedSong(playCount: 11, lastPlayedDate: nil)
    parse(makeResponse(songAttributes: #"playCount="4""#))
    XCTAssertEqual(parsedSong?.playCount, 11)
  }

  func testAbsentPlayCountAttributeLeavesLocalCountUntouched() {
    makeLocallyPlayedSong(playCount: 5, lastPlayedDate: nil)
    parse(makeResponse(songAttributes: #"created="2026-08-01T10:00:00Z""#))
    XCTAssertEqual(parsedSong?.playCount, 5)
  }

  // MARK: - lastPlayedDate merge

  func testServerPlayedDateIsAdoptedWhenNoLocalDateExists() {
    parse(makeResponse(songAttributes: #"played="2026-08-10T09:00:00Z""#))
    XCTAssertEqual(parsedSong?.lastTimePlayed, date("2026-08-10T09:00:00Z"))
  }

  func testLaterServerPlayedDateWins() {
    makeLocallyPlayedSong(playCount: 1, lastPlayedDate: date("2026-08-01T09:00:00Z"))
    parse(makeResponse(songAttributes: #"played="2026-08-10T09:00:00Z""#))
    XCTAssertEqual(parsedSong?.lastTimePlayed, date("2026-08-10T09:00:00Z"))
  }

  /// The mirror case: an older server value never rewinds a fresher local play.
  func testEarlierServerPlayedDateDoesNotRewindLocalDate() {
    makeLocallyPlayedSong(playCount: 1, lastPlayedDate: date("2026-08-15T09:00:00Z"))
    parse(makeResponse(songAttributes: #"played="2026-08-10T09:00:00Z""#))
    XCTAssertEqual(parsedSong?.lastTimePlayed, date("2026-08-15T09:00:00Z"))
  }

  /// `played` arrives without fractional seconds from Go too, so it needs the
  /// same tolerant parsing as `created`.
  func testPlayedDateWithoutFractionalSecondsIsParsed() {
    parse(makeResponse(songAttributes: #"played="2026-08-10T09:00:00Z""#))
    XCTAssertNotNil(parsedSong?.lastTimePlayed)
  }

  func testAbsentPlayedAttributeLeavesLocalDateUntouched() {
    let localDate = date("2026-08-15T09:00:00Z")
    makeLocallyPlayedSong(playCount: 1, lastPlayedDate: localDate)
    parse(makeResponse(songAttributes: #"created="2026-08-01T10:00:00Z""#))
    XCTAssertEqual(parsedSong?.lastTimePlayed, localDate)
  }

  // MARK: - Combined

  /// The realistic sync shape: all three attributes together.
  func testCreatedPlayCountAndPlayedParseTogether() {
    parse(makeResponse(
      songAttributes: #"created="2026-08-01T10:00:00Z" playCount="3" played="2026-08-10T09:00:00Z""#
    ))
    XCTAssertEqual(parsedSong?.addedDate, date("2026-08-01T10:00:00Z"))
    XCTAssertEqual(parsedSong?.playCount, 3)
    XCTAssertEqual(parsedSong?.lastTimePlayed, date("2026-08-10T09:00:00Z"))
  }
}
