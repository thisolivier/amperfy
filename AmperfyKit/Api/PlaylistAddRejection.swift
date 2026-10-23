//
//  PlaylistAddRejection.swift
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

// MARK: - PlaylistAddRejection

/// A playlist song add that the server refused on terms a retry cannot change.
///
/// Servers do reject playlist edits: Navidrome answers Subsonic error 50 for a
/// playlist it imported and considers server-owned, and error 70 once a
/// playlist is gone. Both arrive as an ordinary `ResponseError`, which the add
/// routes used to hand to `EventLogger` — and a notification banner raised
/// while the "Add to Playlist" sheet is presented is dropped on the floor
/// (`AppDelegate.display(title:…)` requires `presentedViewController == nil`).
/// The user was left believing the add had worked.
///
/// This type carries everything an alert needs to say what happened, built in
/// AmperfyKit so the wording is unit tested and the app target only has to
/// decide how to show it.
public struct PlaylistAddRejection: Sendable, Equatable {
  public let playlistName: String
  public let songCount: Int
  /// The server's own words where it sent any, otherwise a plain-English
  /// reading of the API error code.
  public let serverReason: String

  public init(playlistName: String, songCount: Int, serverReason: String) {
    self.playlistName = playlistName
    self.songCount = songCount
    self.serverReason = serverReason
  }

  /// `nil` when `error` is worth retrying, so the caller can keep reporting
  /// those the quiet way.
  public init?(error: Error, playlistName: String, songCount: Int) {
    guard let serverReason = Self.rejectionReason(for: error) else { return nil }
    self.init(playlistName: playlistName, songCount: songCount, serverReason: serverReason)
  }

  /// Names the outcome from the user's point of view — the playlist did not
  /// change — rather than the mechanism.
  public var userFacingTitle: String { "Playlist Not Updated" }

  /// What was refused, why, and the state the playlist is now in.
  ///
  /// Verb agreement is deliberate: a single refused song otherwise read "The
  /// song were not added".
  public var userFacingMessage: String {
    let isSingleSong = songCount == 1
    let songWord = isSingleSong ? "song" : "songs"
    let wasOrWere = isSingleSong ? "was" : "were"
    return """
    The server refused to add \(songCount) \(songWord) to "\(playlistName)".

    \(serverReason)

    The \(songWord) \(wasOrWere) not added and your local copy of the playlist is unchanged.
    """
  }

  /// A human-readable reason when `error` is a refusal no retry can fix, `nil`
  /// when the failure is transient and the existing quiet reporting is right.
  ///
  /// Only API error codes that mean "this will never work" count. Everything
  /// else — no response, a 5xx, an unparseable body, a playlist whose create
  /// request has not landed yet (`BackendError.incorrectServerBehavior`) — is
  /// treated as transient, because a modal alert over a bad minute of network
  /// would be worse than the banner it replaces.
  static func rejectionReason(for error: Error) -> String? {
    guard let responseError = error as? ResponseError, responseError.type == .api
    else { return nil }

    let serverMessage = responseError.message.trimmingCharacters(in: .whitespacesAndNewlines)
    func reason(_ fallback: String) -> String {
      serverMessage.isEmpty ? fallback : serverMessage
    }

    switch responseError.asSubsonicError {
    case .userIsNotAuthorized:
      return reason("The server is not accepting changes to this playlist (error 50).")
    case .requestedDataNotFound:
      return reason("The server no longer has this playlist (error 70).")
    default:
      break
    }

    switch responseError.asAmpacheError {
    case .accessDenied, .failedAccessCheck:
      return reason("The server is not accepting changes to this playlist.")
    case .notFound:
      return reason("The server no longer has this playlist.")
    default:
      return nil
    }
  }
}
