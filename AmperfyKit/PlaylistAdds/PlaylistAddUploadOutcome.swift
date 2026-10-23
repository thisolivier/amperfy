//
//  PlaylistAddUploadOutcome.swift
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

import Foundation

// MARK: - PlaylistAddFlushSummary

/// What one pass of ``PlaylistAddUploadService`` did.
///
/// Returned rather than only logged so a caller can report a real outcome. The
/// over-100-songs confirmation used to claim "successfully synced to the
/// server" from outside the `do`/`catch` that had just swallowed the error.
public struct PlaylistAddFlushSummary: Sendable, Equatable {
  /// Songs whose upload landed and whose queue entries are now deleted.
  public let uploadedSongCount: Int
  /// Playlists whose batch landed in full.
  public let uploadedPlaylistCount: Int
  /// Songs rolled back locally after a permanent server refusal.
  public let permanentlyFailedSongCount: Int
  /// Songs still queued after a transient failure.
  public let stillPendingSongCount: Int
  /// `true` when the pass did not even attempt the network because the app is
  /// offline. Everything stays queued — this is not a success.
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

/// Errors the playlist-add upload path raises itself, as opposed to relaying
/// from the backend.
public enum PlaylistAddUploadError: LocalizedError, Equatable {
  /// The request was never made because there is no connection. Distinct from
  /// success: `guard isSyncAllowed else { return }` inside
  /// `syncUpload(playlistToAddSongs:)` used to report this condition as a
  /// completed upload, which is how adds were lost without a trace.
  case offline
  /// The server refused the add on terms a retry cannot change, so the local
  /// append has been rolled back. Carries everything needed to tell the user
  /// what happened and to which playlist.
  case permanentlyRefused(playlistName: String, songCount: Int, serverReason: String)

  public var errorDescription: String? {
    switch self {
    case .offline:
      return "No connection to the server. The change is queued and will be sent later."
    case let .permanentlyRefused(playlistName, songCount, serverReason):
      let songWord = songCount == 1 ? "Song" : "Songs"
      return """
      The server refused to add \(songCount) \(songWord) to "\(playlistName)". \(serverReason) \
      The \(songWord) have been removed from the Playlist on this device again.
      """
    }
  }
}
