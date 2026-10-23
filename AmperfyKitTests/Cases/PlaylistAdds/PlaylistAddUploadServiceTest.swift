//
//  PlaylistAddUploadServiceTest.swift
//  AmperfyKitTests
//
//  Created for AMP-28 — playlist song adds became a durable, retried queue.
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

@MainActor
final class PlaylistAddUploadServiceTest: XCTestCase {
  private var coreDataHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PendingPlaylistSongAddStore!
  private var syncer: RECORDING_PlaylistAddSyncer!

  private var isOnline = true
  private var reportedPermanentFailures = [PlaylistAddPermanentFailure]()
  private var reportedTransientErrors = [Error]()

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PendingPlaylistSongAddStore(library: library)
    syncer = RECORDING_PlaylistAddSyncer()
    isOnline = true
    reportedPermanentFailures = []
    reportedTransientErrors = []
  }

  private func makeService() -> PlaylistAddUploadService {
    PlaylistAddUploadService(
      store: store,
      librarySyncer: syncer,
      account: account,
      isOnline: { [weak self] in self?.isOnline ?? false },
      reportPermanentFailure: { [weak self] failure in
        self?.reportedPermanentFailures.append(failure)
      },
      reportTransientFailure: { [weak self] error in
        self?.reportedTransientErrors.append(error)
      }
    )
  }

  @discardableResult
  private func makeSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  private func makePlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  // MARK: - Success

  /// The happy path: the batch uploads, the rows clear, and the playlist is
  /// re-fetched to reconcile — in that order. The re-fetch is only safe once
  /// the server actually holds the songs.
  func testSuccessClearsRowsThenReconciles() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)

    var pendingCountAtReconcileTime = -1
    syncer.onSyncDown = { [weak self] _ in
      pendingCountAtReconcileTime = self?.store.pendingAdds(for: playlist).count ?? -1
    }

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedSongCount, 2)
    XCTAssertEqual(summary.uploadedPlaylistCount, 1)
    XCTAssertEqual(summary.stillPendingSongCount, 0)
    XCTAssertTrue(summary.isFullyDrained)
    XCTAssertTrue(summary.didUploadAnything)
    XCTAssertEqual(store.pendingAddCount(for: account), 0, "resolved rows are deleted")
    XCTAssertEqual(
      syncer.recordedCalls,
      [
        .upload(playlistName: "My Mix", songIds: ["t-1", "t-2"]),
        .syncDown(playlistName: "My Mix"),
      ],
      "upload first, then reconcile"
    )
    XCTAssertEqual(
      pendingCountAtReconcileTime,
      0,
      "rows must already be cleared when the reconciling fetch runs, so the guard does not re-append the server's own copy"
    )
    XCTAssertTrue(reportedPermanentFailures.isEmpty)
    XCTAssertTrue(reportedTransientErrors.isEmpty)
  }

  /// One request per playlist, even when the adds arrived in several taps.
  func testOneRequestPerPlaylistAcrossMultipleEnqueues() async throws {
    let firstPlaylist = makePlaylist(id: "pl-1", name: "First")
    let secondPlaylist = makePlaylist(id: "pl-2", name: "Second")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    let songThree = makeSong(id: "t-3")
    library.saveContext()

    let baseDate = Date(timeIntervalSince1970: 1_000)
    store.enqueue(songs: [songOne], to: firstPlaylist, account: account, now: baseDate)
    store.enqueue(
      songs: [songTwo],
      to: secondPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(1)
    )
    store.enqueue(
      songs: [songThree],
      to: firstPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(2)
    )

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedPlaylistCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 3)
    XCTAssertEqual(syncer.uploadCallCount, 2)
    XCTAssertEqual(
      syncer.recordedCalls.first,
      .upload(playlistName: "First", songIds: ["t-1", "t-3"]),
      "both of the first playlist's adds ride in one request, in tap order"
    )
  }

  /// Nothing queued, nothing sent.
  func testEmptyQueueMakesNoRequest() async throws {
    let summary = await makeService().flushPendingAdds()

    XCTAssertTrue(syncer.recordedCalls.isEmpty)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertFalse(summary.wasSkippedOffline)
  }

  /// `enqueueAndFlush` records before it sends, so the intent is durable even
  /// if the request never comes back.
  func testEnqueueAndFlushRecordsBeforeSending() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()

    var rowExistedAtUploadTime = false
    syncer.onSyncUpload = { [weak self] playlist, _ in
      rowExistedAtUploadTime = !(self?.store.pendingAdds(for: playlist).isEmpty ?? true)
    }

    let summary = await makeService().enqueueAndFlush(songs: [song], to: playlist)

    XCTAssertTrue(rowExistedAtUploadTime, "the queue row must exist before the request goes out")
    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Route 2 ordering (local-first)

  /// Route 2's regression, pinned at the level where the ordering now lives.
  ///
  /// The old `AddToPlaylistManager.doneBarButtonPressed` uploaded first and
  /// appended locally only afterwards, so during the round-trip the songs were
  /// in neither the playlist nor any durable record — and a failure left them
  /// in neither for good. Both routes now append locally and write the queue
  /// row *before* the request, which is what this asserts: at the moment the
  /// upload is attempted, the songs are already visible AND already owed.
  func testSongsAreVisibleAndOwedBeforeTheUploadIsAttempted() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()

    // Exactly what both routes do, in their order.
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)

    var localIdsAtUploadTime = [String]()
    var owedIdsAtUploadTime = [String]()
    syncer.onSyncUpload = { [weak self] playlist, _ in
      localIdsAtUploadTime = playlist.playables.map(\.id)
      owedIdsAtUploadTime = self?.store.pendingAdds(for: playlist).compactMap(\.song?.id) ?? []
    }

    await makeService().flushPendingAdds()

    XCTAssertEqual(localIdsAtUploadTime, ["t-1", "t-2"], "visible locally before the request")
    XCTAssertEqual(owedIdsAtUploadTime, ["t-1", "t-2"], "and durably owed before the request")
  }

  // MARK: - Permanent refusal

  /// Subsonic error 50: the rows are resolved, the optimistic append is rolled
  /// back, and a modal-worthy failure is handed up. Retrying would re-send a
  /// request the server refuses forever; leaving the items would show songs the
  /// playlist does not contain.
  func testPermanentRefusalRollsBackAndReportsLoudly() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let existingSong = makeSong(id: "t-existing")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    playlist.append(playable: existingSong)
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    syncer.uploadErrorsToThrow = [
      PlaylistAddTestErrors.subsonicNotAuthorized(message: "Playlist is read-only"),
    ]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertEqual(summary.stillPendingSongCount, 0)
    XCTAssertEqual(store.pendingAddCount(for: account), 0, "a refused add is not retried")
    XCTAssertEqual(
      playlist.playables.map(\.id),
      ["t-existing"],
      "the optimistic append is rolled back; pre-existing items are untouched"
    )
    XCTAssertEqual(reportedPermanentFailures.count, 1)
    XCTAssertEqual(reportedPermanentFailures.first?.playlistName, "My Mix")
    XCTAssertEqual(reportedPermanentFailures.first?.songCount, 2)
    XCTAssertEqual(reportedPermanentFailures.first?.serverReason, "Playlist is read-only")
    XCTAssertTrue(reportedTransientErrors.isEmpty, "a refusal is not a banner")
    XCTAssertEqual(syncer.syncDownCallCount, 0, "no reconciling fetch after a refusal")
  }

  /// Subsonic error 70 is the other permanent case, and with no server message
  /// the user still gets a plain-English reason rather than a bare code.
  func testSubsonicSeventyIsPermanentWithAFallbackReason() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.subsonicDataNotFound()]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 1)
    XCTAssertTrue(playlist.playables.isEmpty)
    XCTAssertEqual(reportedPermanentFailures.count, 1)
    XCTAssertFalse(reportedPermanentFailures.first?.serverReason.isEmpty ?? true)
  }

  /// A refusal on one playlist must not stop another playlist's add landing.
  func testPermanentRefusalOnOnePlaylistDoesNotBlockTheNext() async throws {
    let refusingPlaylist = makePlaylist(id: "pl-1", name: "Refuses")
    let acceptingPlaylist = makePlaylist(id: "pl-2", name: "Accepts")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    library.saveContext()

    let baseDate = Date(timeIntervalSince1970: 1_000)
    refusingPlaylist.append(playable: songOne)
    acceptingPlaylist.append(playable: songTwo)
    store.enqueue(songs: [songOne], to: refusingPlaylist, account: account, now: baseDate)
    store.enqueue(
      songs: [songTwo],
      to: acceptingPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(1)
    )
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.subsonicNotAuthorized()]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 1)
    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertTrue(refusingPlaylist.playables.isEmpty, "rolled back")
    XCTAssertEqual(acceptingPlaylist.playables.map(\.id), ["t-2"], "still landed")
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Transient failure

  /// A 5xx keeps the rows, counts the attempt, leaves the local items in place
  /// and banners once. Nothing is lost and nothing is claimed.
  func testTransientFailureKeepsRowsAndLocalItems() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.serverSideHttpFailure()]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertEqual(summary.permanentlyFailedSongCount, 0)
    XCTAssertFalse(summary.isFullyDrained)
    XCTAssertEqual(store.pendingAddCount(for: account), 2, "rows stay queued for retry")
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1", "t-2"], "local items are NOT rolled back")
    XCTAssertEqual(store.pendingAdds(for: playlist).first?.attemptCount, 1)
    XCTAssertEqual(reportedTransientErrors.count, 1)
    XCTAssertTrue(reportedPermanentFailures.isEmpty)
    XCTAssertEqual(syncer.syncDownCallCount, 0, "no reconciling fetch while the add is unproven")
  }

  /// A timeout is transient too — the request may well have been received, so
  /// giving up on it would be the worse guess.
  func testNetworkTimeoutIsTransient() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.networkTimeout()]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"])
  }

  /// The user gets one banner per pass, not one per failing playlist.
  func testTransientFailuresBannerOncePerPass() async throws {
    let firstPlaylist = makePlaylist(id: "pl-1", name: "First")
    let secondPlaylist = makePlaylist(id: "pl-2", name: "Second")
    let songOne = makeSong(id: "t-1")
    let songTwo = makeSong(id: "t-2")
    library.saveContext()

    let baseDate = Date(timeIntervalSince1970: 1_000)
    store.enqueue(songs: [songOne], to: firstPlaylist, account: account, now: baseDate)
    store.enqueue(
      songs: [songTwo],
      to: secondPlaylist,
      account: account,
      now: baseDate.addingTimeInterval(1)
    )
    syncer.uploadErrorsToThrow = [
      PlaylistAddTestErrors.serverSideHttpFailure(),
      PlaylistAddTestErrors.serverSideHttpFailure(),
    ]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 2)
    XCTAssertEqual(reportedTransientErrors.count, 1, "one banner, two failures")
  }

  /// A queued add retries on the next pass and lands. This is the whole point
  /// of the queue, and it is what the scene-foreground hook triggers.
  func testQueuedAddLandsOnARetryPass() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.serverSideHttpFailure()]

    let firstSummary = await makeService().flushPendingAdds()
    XCTAssertEqual(firstSummary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)

    let secondSummary = await makeService().flushPendingAdds()

    XCTAssertEqual(secondSummary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
    XCTAssertEqual(syncer.uploadCallCount, 2)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"])
  }

  // MARK: - Offline

  /// Offline is not success and not failure: no request, no row touched, no
  /// attempt counted, and the summary says so. The old
  /// `guard isSyncAllowed else { return }` reported this same condition as a
  /// completed upload, which is the primitive that lost adds silently.
  func testOfflineLeavesEverythingQueuedAndIsNotASuccess() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let songs = [makeSong(id: "t-1"), makeSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    isOnline = false

    let summary = await makeService().flushPendingAdds()

    XCTAssertTrue(summary.wasSkippedOffline)
    XCTAssertFalse(summary.isFullyDrained, "offline must never read as drained")
    XCTAssertFalse(summary.didUploadAnything)
    XCTAssertEqual(summary.stillPendingSongCount, 2)
    XCTAssertTrue(syncer.recordedCalls.isEmpty, "no request is attempted offline")
    XCTAssertEqual(store.pendingAddCount(for: account), 2)
    XCTAssertEqual(
      store.pendingAdds(for: playlist).first?.attemptCount,
      0,
      "an attempt that never left the device is not an attempt"
    )
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1", "t-2"], "the local add stands")
    XCTAssertTrue(reportedPermanentFailures.isEmpty)
    XCTAssertTrue(reportedTransientErrors.isEmpty)
  }

  /// Coming back online drains what offline left queued.
  func testComingBackOnlineDrainsTheQueue() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)

    isOnline = false
    await makeService().flushPendingAdds()
    XCTAssertEqual(store.pendingAddCount(for: account), 1)

    isOnline = true
    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Failure classification

  /// The classifier is the line between "give up and tell the user" and "keep
  /// trying". Getting it wrong in either direction loses data or spams.
  func testOnlySubsonicFiftyAndSeventyArePermanent() throws {
    XCTAssertNotNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.subsonicNotAuthorized()
    ))
    XCTAssertNotNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.subsonicDataNotFound()
    ))

    XCTAssertNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.serverSideHttpFailure()
    ))
    XCTAssertNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.networkTimeout()
    ))
    XCTAssertNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddUploadError.offline
    ))
    XCTAssertNil(
      PlaylistAddUploadService.permanentRefusalReason(
        for: BackendError.incorrectServerBehavior(message: "playlist id still empty")
      ),
      "a playlist whose create has not landed yet must be retried, not discarded"
    )
    XCTAssertNil(PlaylistAddUploadService.permanentRefusalReason(
      for: ResponseError(type: .xml, statusCode: 0, message: "unparseable")
    ))
  }

  /// `PlaylistAddUploadError.offline` thrown by the syncers is retryable, so an
  /// add made while the online check raced the request stays queued.
  func testOfflineErrorFromTheSyncerIsTransient() async throws {
    let playlist = makePlaylist(id: "pl-1", name: "My Mix")
    let song = makeSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddUploadError.offline]

    let summary = await makeService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertTrue(reportedPermanentFailures.isEmpty)
  }
}
