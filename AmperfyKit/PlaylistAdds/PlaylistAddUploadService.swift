//
//  PlaylistAddUploadService.swift
//  AmperfyKit
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

import CoreData
import Foundation
import os.log

// MARK: - PlaylistAddUploadService

/// Drains ``PendingPlaylistSongAddStore`` to the server.
///
/// One pass per call, one request per playlist, three outcomes per request and
/// no fourth:
///
/// - **Landed.** The rows are deleted, then the playlist is re-fetched. The
///   re-fetch is the point: reconciliation is server-wins and positional
///   (`SsPlaylistSongsParserDelegate` rewrites the items from the envelope), so
///   it is only safe once the server actually holds the songs — which it now
///   does. Running it before the upload is what used to erase the local tail.
/// - **Permanently refused** (Subsonic 50 / 70). The rows are deleted, the
///   optimistic local append is ROLLED BACK, and the caller is handed a
///   ``PlaylistAddPermanentFailure`` to put in front of the user as a modal.
///   Leaving the rows queued here would retry a request the server will refuse
///   forever; leaving the local items in place would show songs the playlist
///   does not contain.
/// - **Transient** (offline, timeout, 5xx, a malformed reply). The rows stay
///   queued, their attempt count goes up, and the reason is recorded. The user
///   gets one non-blocking banner per pass, not one per playlist.
///
/// There is no attempt ceiling and no backoff: the retry rate is already
/// bounded by how often a flush runs (app foreground, and the moment an add is
/// made), and a song the user put in a playlist is not something to give up on.
/// Same reasoning as `PlaylistFolderStore.retryPendingFolderCreations`.
@MainActor
public final class PlaylistAddUploadService {
  /// Called on the main actor with a refusal the user must be shown as a modal
  /// alert — never a banner, which any presented view controller swallows.
  public typealias PermanentFailureReporter = @MainActor (PlaylistAddPermanentFailure) -> ()
  /// Called on the main actor at most once per pass for a retryable failure.
  public typealias TransientFailureReporter = @MainActor (Error) -> ()

  private let store: PendingPlaylistSongAddStore
  private let librarySyncer: LibrarySyncer
  private let account: Account
  private let isOnline: @MainActor () -> Bool
  private let reportPermanentFailure: PermanentFailureReporter?
  private let reportTransientFailure: TransientFailureReporter?

  private let logger = Logger(subsystem: "Amperfy", category: "PlaylistAddUploadService")

  /// Guards against two overlapping passes double-sending the same batch (an
  /// add made while a foreground flush is still in flight).
  private var isFlushInProgress = false

  public init(
    store: PendingPlaylistSongAddStore,
    librarySyncer: LibrarySyncer,
    account: Account,
    isOnline: @escaping @MainActor () -> Bool,
    reportPermanentFailure: PermanentFailureReporter? = nil,
    reportTransientFailure: TransientFailureReporter? = nil
  ) {
    self.store = store
    self.librarySyncer = librarySyncer
    self.account = account
    self.isOnline = isOnline
    self.reportPermanentFailure = reportPermanentFailure
    self.reportTransientFailure = reportTransientFailure
  }

  // MARK: - Enqueue + flush

  /// Record the add and immediately try to send it.
  ///
  /// The recording is synchronous and saved before the attempt, so the intent
  /// survives the app being killed, the request failing, or the device being
  /// offline. Offline is NOT a success here: the rows simply stay queued.
  @discardableResult
  public func enqueueAndFlush(songs: [Song], to playlist: Playlist) async
    -> PlaylistAddFlushSummary {
    store.enqueue(songs: songs, to: playlist, account: account)
    return await flushPendingAdds()
  }

  /// Record the add without waiting for the network. Used where the caller
  /// wants the UI to move on at once; pair it with ``flushPendingAdds()`` in a
  /// detached task.
  public func enqueue(songs: [Song], to playlist: Playlist) {
    store.enqueue(songs: songs, to: playlist, account: account)
  }

  /// One drain pass over everything this account owes the server.
  @discardableResult
  public func flushPendingAdds() async -> PlaylistAddFlushSummary {
    guard !isFlushInProgress else {
      logger.info("Playlist-add flush already in progress; skipping this trigger.")
      return PlaylistAddFlushSummary(stillPendingSongCount: store.pendingAddCount(for: account))
    }
    isFlushInProgress = true
    defer { isFlushInProgress = false }

    let batches = store.pendingBatches(for: account)
    guard !batches.isEmpty else { return PlaylistAddFlushSummary() }

    guard isOnline() else {
      // Deliberately not an error and deliberately not a success: the work is
      // still owed and the rows prove it.
      let stillPendingSongCount = batches.reduce(0) { $0 + $1.songs.count }
      logger.info(
        """
        Offline: \(stillPendingSongCount, privacy: .public) playlist song add(s) stay queued.
        """
      )
      return PlaylistAddFlushSummary(
        stillPendingSongCount: stillPendingSongCount,
        wasSkippedOffline: true
      )
    }

    var uploadedSongCount = 0
    var uploadedPlaylistCount = 0
    var permanentlyFailedSongCount = 0
    var stillPendingSongCount = 0
    var hasReportedTransientFailureThisPass = false

    for batch in batches {
      do {
        try await librarySyncer.syncUpload(
          playlistToAddSongs: batch.playlist,
          songs: batch.songs
        )
        // Resolve the rows BEFORE the re-fetch: the re-fetch runs through the
        // reconciliation guard, which re-appends anything still queued. With
        // the rows gone it correctly leaves the server's own copy alone.
        store.delete(batch.pendingAdds)
        uploadedSongCount += batch.songs.count
        uploadedPlaylistCount += 1
        logger.info(
          """
          Uploaded \(batch.songs.count, privacy: .public) song(s) to a playlist; \
          re-fetching it to reconcile.
          """
        )
        // Non-fatal: the songs are on the server either way. A failed re-fetch
        // only means the local order may lag until the next sync.
        try? await librarySyncer.syncDown(playlist: batch.playlist)
      } catch {
        if let serverReason = Self.permanentRefusalReason(for: error) {
          let failure = PlaylistAddPermanentFailure(
            playlistName: batch.playlist.name,
            songCount: batch.songs.count,
            serverReason: serverReason
          )
          store.delete(batch.pendingAdds)
          rollBackLocalAppend(for: batch)
          permanentlyFailedSongCount += batch.songs.count
          logger.error(
            """
            Server permanently refused \(batch.songs.count, privacy: .public) playlist song \
            add(s); rolled the local append back.
            """
          )
          reportPermanentFailure?(failure)
        } else {
          store.recordTransientFailure(
            for: batch.pendingAdds,
            message: error.localizedDescription
          )
          stillPendingSongCount += batch.songs.count
          if !hasReportedTransientFailureThisPass {
            hasReportedTransientFailureThisPass = true
            reportTransientFailure?(error)
          }
        }
      }
    }

    return PlaylistAddFlushSummary(
      uploadedSongCount: uploadedSongCount,
      uploadedPlaylistCount: uploadedPlaylistCount,
      permanentlyFailedSongCount: permanentlyFailedSongCount,
      stillPendingSongCount: stillPendingSongCount
    )
  }

  // MARK: - Classifying failures

  /// A human-readable reason when `error` is a refusal no retry can fix, `nil`
  /// when the failure is worth retrying.
  ///
  /// Only the two Subsonic codes that mean "this will never work" are treated
  /// as permanent. Everything else — no response, a 5xx, an unparseable body,
  /// a playlist whose create has not landed yet
  /// (`BackendError.incorrectServerBehavior`) — is retryable, because treating
  /// it as permanent would throw away an add over a bad minute of network.
  public static func permanentRefusalReason(for error: Error) -> String? {
    guard let responseError = error as? ResponseError, responseError.type == .api
    else { return nil }

    let serverMessage = responseError.message.trimmingCharacters(in: .whitespacesAndNewlines)
    switch responseError.asSubsonicError {
    case .userIsNotAuthorized:
      return serverMessage.isEmpty
        ? "The server is not accepting changes to this playlist (error 50)."
        : serverMessage
    case .requestedDataNotFound:
      return serverMessage.isEmpty
        ? "The server no longer has this playlist (error 70)."
        : serverMessage
    default:
      return nil
    }
  }

  // MARK: - Rollback

  /// Undo the optimistic local append for a batch the server refused, one
  /// occurrence per queued row so a deliberate duplicate add removes exactly
  /// the copies it added.
  ///
  /// One save for the whole batch, not one per song. The queue rows are already
  /// resolved by the time this runs, so a looped rollback interrupted part-way
  /// would have left phantom songs with nothing queued to correct them; and
  /// saving per song drove a separate fetched-results update each time, walking
  /// the list and its header down through every intermediate count.
  private func rollBackLocalAppend(for batch: PendingPlaylistSongAddBatch) {
    batch.playlist.remove(firstOccurrencesOfPlayables: batch.songs)
  }
}
