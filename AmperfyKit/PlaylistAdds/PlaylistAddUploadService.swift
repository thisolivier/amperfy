//
//  PlaylistAddUploadService.swift
//  AmperfyKit
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

import CoreData
import Foundation
import os.log

/// Drains ``PendingPlaylistSongAddStore`` to the server.
///
/// One pass per call, one request per playlist, three outcomes per request and
/// no fourth:
///
/// - **Landed.** The queued adds are deleted, then the playlist is re-fetched.
///   The re-fetch is the point: reconciliation is server-wins and positional,
///   so it is only safe once the server actually holds the songs — which it now
///   does. Running it before the upload is what used to erase the local tail.
/// - **Permanently refused.** The queued adds are deleted, the optimistic local
///   append is rolled back, and the caller is handed a
///   ``PlaylistAddUploadError/permanentlyRefused(playlistName:songCount:serverReason:)``
///   to report. Keeping the adds queued would retry a request the server
///   refuses forever; keeping the local items would show songs the playlist
///   does not contain.
/// - **Transient** (offline, timeout, 5xx, an unparseable reply). The adds stay
///   queued, their attempt count goes up, and the reason is recorded. The user
///   gets one report per pass, not one per playlist.
///
/// There is no attempt ceiling and no backoff: the retry rate is already
/// bounded by how often a pass runs — when an add is made, and when the app
/// comes back to the foreground.
@MainActor
public final class PlaylistAddUploadService {
  /// Called on the main actor for a failure the user should be told about.
  public typealias FailureReporter = @MainActor (Error) -> ()

  private let store: PendingPlaylistSongAddStore
  private let librarySyncer: LibrarySyncer
  private let account: Account
  private let isOnline: @MainActor () -> Bool
  private let reportFailure: FailureReporter?

  private let log = OSLog(subsystem: "Amperfy", category: "PlaylistAddUploadService")

  /// Guards two overlapping passes from double-sending the same batch — an add
  /// made while a foreground pass is still in flight.
  private var isFlushInProgress = false

  public init(
    store: PendingPlaylistSongAddStore,
    librarySyncer: LibrarySyncer,
    account: Account,
    isOnline: @escaping @MainActor () -> Bool,
    reportFailure: FailureReporter? = nil
  ) {
    self.store = store
    self.librarySyncer = librarySyncer
    self.account = account
    self.isOnline = isOnline
    self.reportFailure = reportFailure
  }

  // MARK: - Queue and flush

  /// Record the add and immediately try to send it.
  ///
  /// The recording is saved before the attempt, so the intent survives the app
  /// being killed, the request failing, or the device being offline. Offline is
  /// not a success here: the queued adds simply stay queued.
  @discardableResult
  public func enqueueAndFlush(songs: [Song], to playlist: Playlist) async
    -> PlaylistAddFlushSummary {
    store.enqueue(songs: songs, to: playlist, account: account)
    return await flushPendingAdds()
  }

  /// Record the add without waiting for the network. Pair it with
  /// ``flushPendingAdds()`` when the UI should move on at once.
  public func enqueue(songs: [Song], to playlist: Playlist) {
    store.enqueue(songs: songs, to: playlist, account: account)
  }

  /// One drain pass over everything this account owes the server.
  @discardableResult
  public func flushPendingAdds() async -> PlaylistAddFlushSummary {
    guard !isFlushInProgress else {
      os_log(
        "Playlist add upload already in progress, skipping this trigger",
        log: log,
        type: .info
      )
      return PlaylistAddFlushSummary(stillPendingSongCount: store.pendingAddCount(for: account))
    }
    isFlushInProgress = true
    defer { isFlushInProgress = false }

    let batches = store.pendingBatches(for: account)
    guard !batches.isEmpty else { return PlaylistAddFlushSummary() }

    guard isOnline() else {
      // Deliberately neither an error nor a success: the work is still owed and
      // the queue proves it.
      let stillPendingSongCount = batches.reduce(0) { $0 + $1.songs.count }
      os_log(
        "Offline: %i playlist song add(s) stay queued",
        log: log,
        type: .info,
        stillPendingSongCount
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
        // Resolve the queued adds BEFORE the re-fetch: the re-fetch runs through
        // the reconciliation guard, which re-appends anything still queued. With
        // the queue empty it correctly leaves the server's own copy alone.
        store.delete(batch.pendingAdds)
        uploadedSongCount += batch.songs.count
        uploadedPlaylistCount += 1
        os_log(
          "Uploaded %i song(s) to playlist \"%s\", re-fetching it to reconcile",
          log: log,
          type: .info,
          batch.songs.count,
          batch.playlist.name
        )
        // Non-fatal: the songs are on the server either way. A failed re-fetch
        // only means the local order may lag until the next sync.
        try? await librarySyncer.syncDown(playlist: batch.playlist)
      } catch {
        if let serverReason = Self.permanentRefusalReason(for: error) {
          store.delete(batch.pendingAdds)
          rollBackLocalAppend(for: batch)
          permanentlyFailedSongCount += batch.songs.count
          os_log(
            "Server permanently refused %i playlist song add(s), rolled the local append back",
            log: log,
            type: .error,
            batch.songs.count
          )
          reportFailure?(PlaylistAddUploadError.permanentlyRefused(
            playlistName: batch.playlist.name,
            songCount: batch.songs.count,
            serverReason: serverReason
          ))
        } else {
          store.recordTransientFailure(
            for: batch.pendingAdds,
            message: error.localizedDescription
          )
          stillPendingSongCount += batch.songs.count
          if !hasReportedTransientFailureThisPass {
            hasReportedTransientFailureThisPass = true
            reportFailure?(error)
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
  /// Only the backend codes that mean "this will never work" count as
  /// permanent. Everything else — no response, a 5xx, an unparseable body, a
  /// playlist whose create has not landed yet
  /// (`BackendError.incorrectServerBehavior`) — is retried, because treating it
  /// as permanent would throw an add away over a bad minute of network.
  public static func permanentRefusalReason(for error: Error) -> String? {
    guard let responseError = error as? ResponseError, responseError.type == .api
    else { return nil }

    let serverMessage = responseError.message.trimmingCharacters(in: .whitespacesAndNewlines)
    switch responseError.asSubsonicError {
    case .userIsNotAuthorized:
      return serverMessage.isEmpty
        ? "The server is not accepting changes to this Playlist (error 50)." : serverMessage
    case .requestedDataNotFound:
      return serverMessage.isEmpty
        ? "The server does not have this Playlist anymore (error 70)." : serverMessage
    default:
      break
    }
    switch responseError.asAmpacheError {
    case .notFound:
      return serverMessage.isEmpty
        ? "The server does not have this Playlist anymore (error 4704)." : serverMessage
    case .badRequest:
      return serverMessage.isEmpty
        ? "The server rejected this request (error 4710)." : serverMessage
    case .failedAccessCheck:
      return serverMessage.isEmpty
        ? "The server is not accepting changes to this Playlist (error 4742)." : serverMessage
    default:
      return nil
    }
  }

  // MARK: - Rollback

  /// Undo the optimistic local append for a batch the server refused, one
  /// occurrence per queued add so a deliberate duplicate removes exactly the
  /// copies it added.
  private func rollBackLocalAppend(for batch: PendingPlaylistSongAddBatch) {
    for song in batch.songs {
      batch.playlist.remove(firstOccurrenceOfPlayable: song)
    }
  }
}
