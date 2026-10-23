//
//  PlaylistAddUploadOutcome.swift
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

import Foundation

// MARK: - PlaylistAddPermanentFailure

/// A playlist add the server refused on terms a retry cannot change.
///
/// This is the case the old code hid: the Navidrome fork answers Subsonic error
/// 50 ("not authorized for the given operation") for a playlist it considers
/// server-synced, and error 70 for one it no longer has. Both used to arrive as
/// a notification banner, which the presented "Add to Playlist" modal
/// suppressed outright (AMP-6), so the user's only evidence was the songs
/// quietly vanishing on the next fetch.
///
/// Everything a modal alert needs to say what happened and to whom, carried out
/// of AmperfyKit so the app layer owns the presentation.
public struct PlaylistAddPermanentFailure: Sendable, Equatable {
  public let playlistName: String
  public let songCount: Int
  /// The server's own words where it gave any, otherwise a plain-English
  /// reading of the Subsonic error code.
  public let serverReason: String

  public init(playlistName: String, songCount: Int, serverReason: String) {
    self.playlistName = playlistName
    self.songCount = songCount
    self.serverReason = serverReason
  }

  /// The alert title. Names the outcome from the user's point of view — the
  /// playlist did not change — rather than the mechanism.
  public var userFacingTitle: String { "Playlist Not Updated" }

  /// The alert body: what was refused, the server's reason, and the fact that
  /// the local copy has been rolled back so what they see is the truth.
  ///
  /// Built here rather than in the presenter so it is unit-testable; the app
  /// target only decides *how* to show it. Verb agreement included — a single
  /// refused song read "The song were NOT added".
  public var userFacingMessage: String {
    let isSingleSong = songCount == 1
    let songWord = isSingleSong ? "song" : "songs"
    let wasOrWere = isSingleSong ? "was" : "were"
    let hasOrHave = isSingleSong ? "has" : "have"
    return """
    The server refused to add \(songCount) \(songWord) to "\(playlistName)".

    \(serverReason)

    The \(songWord) \(wasOrWere) NOT added, and \(
      hasOrHave
    ) been removed from the playlist on this device.
    """
  }
}

// MARK: - PlaylistAddFlushSummary

/// What one pass of the upload worker did. Returned rather than logged-only so
/// a caller (the >100-songs confirmation, a test) can report a real outcome
/// instead of asserting success before the request has even been made.
public struct PlaylistAddFlushSummary: Sendable, Equatable {
  /// Rows whose upload landed and which have been deleted from the queue.
  public let uploadedSongCount: Int
  /// Playlists whose batch landed in full.
  public let uploadedPlaylistCount: Int
  /// Rows rolled back after a permanent server refusal.
  public let permanentlyFailedSongCount: Int
  /// Rows still queued after a transient failure.
  public let stillPendingSongCount: Int
  /// `true` when the pass did not even attempt the network because the app is
  /// offline. The rows are untouched and still queued — NOT a success.
  public let wasSkippedOffline: Bool

  public init(
    uploadedSongCount: Int = 0,
    uploadedPlaylistCount: Int = 0,
    permanentlyFailedSongCount: Int = 0,
    stillPendingSongCount: Int = 0,
    wasSkippedOffline: Bool = false
  ) {
    self.uploadedSongCount = uploadedSongCount
    self.uploadedPlaylistCount = uploadedPlaylistCount
    self.permanentlyFailedSongCount = permanentlyFailedSongCount
    self.stillPendingSongCount = stillPendingSongCount
    self.wasSkippedOffline = wasSkippedOffline
  }

  /// `true` when nothing at all is outstanding after this pass.
  public var isFullyDrained: Bool {
    !wasSkippedOffline && stillPendingSongCount == 0
  }

  public var didUploadAnything: Bool { uploadedSongCount > 0 }
}

// MARK: - PlaylistAddUploadError

/// Errors the upload worker raises itself (as opposed to relaying from the
/// syncer).
public enum PlaylistAddUploadError: LocalizedError {
  /// The app is offline, so the request was never made. Distinct from success:
  /// the old `guard isSyncAllowed else { return }` inside
  /// `syncUpload(playlistToAddSongs:)` returned THIS condition as a success,
  /// which is the primitive that lost adds silently.
  case offline

  public var errorDescription: String? {
    switch self {
    case .offline:
      return "No connection to the server — the change is queued and will be sent later."
    }
  }
}
