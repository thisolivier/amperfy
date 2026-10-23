//
//  PlaylistAddUploadServiceTest.swift
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
import CoreData
import XCTest

@MainActor
final class PlaylistAddUploadServiceTest: XCTestCase {
  private var cdHelper: CoreDataHelper!
  private var library: LibraryStorage!
  private var account: Account!
  private var store: PendingPlaylistSongAddStore!
  private var syncer: RECORDING_PlaylistAddSyncer!

  private var isOnline = true
  private var reportedErrors = [Error]()

  private var reportedRefusals: [PlaylistAddUploadError] {
    reportedErrors.compactMap { error in
      guard let uploadError = error as? PlaylistAddUploadError,
            case .permanentlyRefused = uploadError else { return nil }
      return uploadError
    }
  }

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    store = PendingPlaylistSongAddStore(library: library)
    syncer = RECORDING_PlaylistAddSyncer()
    isOnline = true
    reportedErrors = []
  }

  private func createService() -> PlaylistAddUploadService {
    PlaylistAddUploadService(
      store: store,
      librarySyncer: syncer,
      account: account,
      isOnline: { [weak self] in self?.isOnline ?? false },
      reportFailure: { [weak self] error in
        self?.reportedErrors.append(error)
      }
    )
  }

  @discardableResult
  private func createSong(id: String) -> Song {
    let song = library.createSong(account: account)
    song.id = id
    return song
  }

  private func createPlaylist(id: String, name: String) -> Playlist {
    let playlist = library.createPlaylist(account: account)
    playlist.id = id
    playlist.name = name
    return playlist
  }

  // MARK: - Success

  /// The happy path: the batch uploads, the queue clears, and the playlist is
  /// re-fetched to reconcile — in that order. The re-fetch is only safe once
  /// the server actually holds the songs.
  func testSuccessClearsTheQueueThenReconciles() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)

    var pendingCountAtReconcileTime = -1
    syncer.onSyncDown = { [weak self] _ in
      pendingCountAtReconcileTime = self?.store.pendingAdds(for: playlist).count ?? -1
    }

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedSongCount, 2)
    XCTAssertEqual(summary.uploadedPlaylistCount, 1)
    XCTAssertEqual(summary.stillPendingSongCount, 0)
    XCTAssertTrue(summary.isFullyDrained)
    XCTAssertTrue(summary.didUploadAnything)
    XCTAssertEqual(store.pendingAddCount(for: account), 0, "resolved adds are deleted")
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
      "the queue must already be clear when the reconciling fetch runs, so the guard does not re-append the server's own copy"
    )
    XCTAssertTrue(reportedErrors.isEmpty)
  }

  /// One request per playlist, even when the adds arrived in several steps.
  func testOneRequestPerPlaylistAcrossMultipleEnqueues() async throws {
    let firstPlaylist = createPlaylist(id: "pl-1", name: "First")
    let secondPlaylist = createPlaylist(id: "pl-2", name: "Second")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
    let songThree = createSong(id: "t-3")
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

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedPlaylistCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 3)
    XCTAssertEqual(syncer.uploadCallCount, 2)
    XCTAssertEqual(
      syncer.recordedCalls.first,
      .upload(playlistName: "First", songIds: ["t-1", "t-3"]),
      "both of the first playlist's adds ride in one request, in selection order"
    )
  }

  func testEmptyQueueMakesNoRequest() async throws {
    let summary = await createService().flushPendingAdds()

    XCTAssertTrue(syncer.recordedCalls.isEmpty)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertFalse(summary.wasSkippedOffline)
  }

  /// `enqueueAndFlush` records before it sends, so the intent is durable even
  /// if the request never comes back.
  func testEnqueueAndFlushRecordsBeforeSending() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()

    var wasQueuedAtUploadTime = false
    syncer.onSyncUpload = { [weak self] playlist, _ in
      wasQueuedAtUploadTime = !(self?.store.pendingAdds(for: playlist).isEmpty ?? true)
    }

    let summary = await createService().enqueueAndFlush(songs: [song], to: playlist)

    XCTAssertTrue(wasQueuedAtUploadTime, "the add must be queued before the request goes out")
    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Local-first ordering

  /// Both add routes used to upload first and append locally only afterwards,
  /// so during the round-trip the songs were in neither the playlist nor any
  /// durable record — and a failure left them in neither for good. They now
  /// append locally and queue the add before the request, which is what this
  /// pins: at the moment the upload is attempted the songs are already visible
  /// and already owed.
  func testSongsAreVisibleAndOwedBeforeTheUploadIsAttempted() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
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

    await createService().flushPendingAdds()

    XCTAssertEqual(localIdsAtUploadTime, ["t-1", "t-2"], "visible locally before the request")
    XCTAssertEqual(owedIdsAtUploadTime, ["t-1", "t-2"], "and durably owed before the request")
  }

  /// A brand-new playlist has no server id until its create request
  /// round-trips, so the queue has to be able to carry work for a playlist that
  /// is not on the server yet. That is why a queued add points at the playlist
  /// object rather than its id.
  func testQueuedAddSurvivesTheServerIdBeingAssignedLater() async throws {
    let playlist = createPlaylist(id: "", name: "Brand New")
    let song = createSong(id: "t-1")
    library.saveContext()

    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    XCTAssertEqual(store.pendingAdds(for: playlist).count, 1)

    // The create round-trip assigns the real id onto this same object.
    playlist.id = "pl-assigned-by-server"
    library.saveContext()

    var playlistIdAtUploadTime: String?
    syncer.onSyncUpload = { playlist, _ in
      playlistIdAtUploadTime = playlist.id
    }

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertEqual(
      playlistIdAtUploadTime,
      "pl-assigned-by-server",
      "the add resolved to the playlist's real id, not the empty one it was queued with"
    )
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Permanent refusal

  /// Subsonic error 50: the queue is cleared, the optimistic append is rolled
  /// back, and the refusal is reported. Retrying would re-send a request the
  /// server refuses forever; keeping the items would show songs the playlist
  /// does not contain.
  func testPermanentRefusalRollsBackAndReports() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let existingSong = createSong(id: "t-existing")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
    library.saveContext()
    playlist.append(playable: existingSong)
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    syncer.uploadErrorsToThrow = [
      PlaylistAddTestErrors.subsonicNotAuthorized(message: "Playlist is read-only"),
    ]

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertEqual(summary.stillPendingSongCount, 0)
    XCTAssertEqual(store.pendingAddCount(for: account), 0, "a refused add is not retried")
    XCTAssertEqual(
      playlist.playables.map(\.id),
      ["t-existing"],
      "the optimistic append is rolled back, pre-existing items are untouched"
    )
    XCTAssertEqual(reportedErrors.count, 1)
    XCTAssertEqual(
      reportedRefusals.first,
      .permanentlyRefused(
        playlistName: "My Mix",
        songCount: 2,
        serverReason: "Playlist is read-only"
      )
    )
    XCTAssertEqual(syncer.syncDownCallCount, 0, "no reconciling fetch after a refusal")
  }

  /// After a rollback the playlist's own `songCount` and `duration` must be
  /// back to their pre-add values — these are the numbers the detail header
  /// renders. `Playlist.songCount` falls back to `remoteSongCount` when the
  /// stored count is zero and `PlaylistMO.willSave()` recomputes the stored
  /// count, so a rollback that failed to save would silently show the server's
  /// count instead.
  func testRollbackRestoresTheSongCountAndDurationTheHeaderShows() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let keptSongs = (1 ... 4).map { index -> Song in
      let song = createSong(id: "t-kept-\(index)")
      song.remoteDuration = 60
      return song
    }
    let refusedSongs = (1 ... 2).map { index -> Song in
      let song = createSong(id: "t-refused-\(index)")
      song.remoteDuration = 60
      return song
    }
    library.saveContext()

    playlist.append(playables: keptSongs)
    let songCountBeforeAdd = playlist.songCount
    let durationBeforeAdd = playlist.duration
    XCTAssertEqual(songCountBeforeAdd, 4)

    playlist.append(playables: refusedSongs)
    store.enqueue(songs: refusedSongs, to: playlist, account: account)
    XCTAssertEqual(playlist.songCount, 6, "the optimistic add shows in the header count")

    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.subsonicNotAuthorized()]
    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 2)
    XCTAssertEqual(playlist.playables.count, 4, "the items are back to four")
    XCTAssertEqual(
      playlist.songCount,
      songCountBeforeAdd,
      "the header's count must match the items, not the pre-rollback value"
    )
    XCTAssertEqual(
      playlist.duration,
      durationBeforeAdd,
      "the header's duration must come back down too"
    )
  }

  /// Subsonic error 70 is the other permanent Subsonic case, and with no server
  /// message the user still gets plain English rather than a bare code.
  func testSubsonicSeventyIsPermanentWithAFallbackReason() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.subsonicDataNotFound()]

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 1)
    XCTAssertTrue(playlist.playables.isEmpty)
    XCTAssertEqual(reportedRefusals.count, 1)
    XCTAssertFalse(reportedRefusals.first?.errorDescription?.isEmpty ?? true)
  }

  /// A refusal on one playlist must not stop another playlist's add landing.
  func testPermanentRefusalOnOnePlaylistDoesNotBlockTheNext() async throws {
    let refusingPlaylist = createPlaylist(id: "pl-1", name: "Refuses")
    let acceptingPlaylist = createPlaylist(id: "pl-2", name: "Accepts")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
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

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.permanentlyFailedSongCount, 1)
    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertTrue(refusingPlaylist.playables.isEmpty, "rolled back")
    XCTAssertEqual(acceptingPlaylist.playables.map(\.id), ["t-2"], "still landed")
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Transient failure

  /// A 5xx keeps the queue, counts the attempt, leaves the local items in place
  /// and reports once. Nothing is lost and nothing is claimed.
  func testTransientFailureKeepsTheQueueAndTheLocalItems() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.serverSideHttpFailure()]

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 2)
    XCTAssertEqual(summary.uploadedSongCount, 0)
    XCTAssertEqual(summary.permanentlyFailedSongCount, 0)
    XCTAssertFalse(summary.isFullyDrained)
    XCTAssertEqual(store.pendingAddCount(for: account), 2, "the adds stay queued for retry")
    XCTAssertEqual(
      playlist.playables.map(\.id),
      ["t-1", "t-2"],
      "local items are NOT rolled back"
    )
    XCTAssertEqual(store.pendingAdds(for: playlist).first?.attemptCount, 1)
    XCTAssertEqual(reportedErrors.count, 1)
    XCTAssertTrue(reportedRefusals.isEmpty)
    XCTAssertEqual(
      syncer.syncDownCallCount,
      0,
      "no reconciling fetch while the add is unproven"
    )
  }

  /// A timeout is transient too — the request may well have been received, so
  /// giving up on it would be the worse guess.
  func testNetworkTimeoutIsTransient() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.networkTimeout()]

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"])
  }

  /// The user gets one report per pass, not one per failing playlist.
  func testTransientFailuresAreReportedOncePerPass() async throws {
    let firstPlaylist = createPlaylist(id: "pl-1", name: "First")
    let secondPlaylist = createPlaylist(id: "pl-2", name: "Second")
    let songOne = createSong(id: "t-1")
    let songTwo = createSong(id: "t-2")
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

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 2)
    XCTAssertEqual(reportedErrors.count, 1, "one report, two failures")
  }

  /// A queued add retries on the next pass and lands. This is the whole point
  /// of the queue, and it is what the scene-foreground hook triggers.
  func testQueuedAddLandsOnARetryPass() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddTestErrors.serverSideHttpFailure()]

    let firstSummary = await createService().flushPendingAdds()
    XCTAssertEqual(firstSummary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)

    let secondSummary = await createService().flushPendingAdds()

    XCTAssertEqual(secondSummary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
    XCTAssertEqual(syncer.uploadCallCount, 2)
    XCTAssertEqual(playlist.playables.map(\.id), ["t-1"])
  }

  // MARK: - Offline

  /// Offline is neither success nor failure: no request, nothing touched, no
  /// attempt counted, and the summary says so. The former
  /// `guard isSyncAllowed else { return }` reported this same condition as a
  /// completed upload, which is what lost adds silently.
  func testOfflineLeavesEverythingQueuedAndIsNotASuccess() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let songs = [createSong(id: "t-1"), createSong(id: "t-2")]
    library.saveContext()
    playlist.append(playables: songs)
    store.enqueue(songs: songs, to: playlist, account: account)
    isOnline = false

    let summary = await createService().flushPendingAdds()

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
    XCTAssertTrue(reportedErrors.isEmpty)
  }

  /// Coming back online drains what offline left queued.
  func testComingBackOnlineDrainsTheQueue() async throws {
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)

    isOnline = false
    await createService().flushPendingAdds()
    XCTAssertEqual(store.pendingAddCount(for: account), 1)

    isOnline = true
    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.uploadedSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 0)
  }

  // MARK: - Failure classification

  /// The classifier is the line between "give up and tell the user" and "keep
  /// trying". Getting it wrong in either direction either loses data or retries
  /// forever.
  func testOnlyOutrightRefusalsArePermanent() throws {
    XCTAssertNotNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.subsonicNotAuthorized()
    ))
    XCTAssertNotNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.subsonicDataNotFound()
    ))
    XCTAssertNotNil(PlaylistAddUploadService.permanentRefusalReason(
      for: PlaylistAddTestErrors.ampacheNotFound()
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
    let playlist = createPlaylist(id: "pl-1", name: "My Mix")
    let song = createSong(id: "t-1")
    library.saveContext()
    playlist.append(playable: song)
    store.enqueue(songs: [song], to: playlist, account: account)
    syncer.uploadErrorsToThrow = [PlaylistAddUploadError.offline]

    let summary = await createService().flushPendingAdds()

    XCTAssertEqual(summary.stillPendingSongCount, 1)
    XCTAssertEqual(store.pendingAddCount(for: account), 1)
    XCTAssertTrue(reportedRefusals.isEmpty)
  }
}
