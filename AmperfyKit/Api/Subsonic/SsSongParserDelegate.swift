//
//  SsSongParserDelegate.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 05.04.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

class SsSongParserDelegate: SsPlayableParserDelegate {
  var songBuffer: Song?
  var parsedSongs = [Song]()
  var guessedArtist: Artist?
  var guessedAlbum: Album?
  var guessedGenre: Genre?

  /// RFC3339 with fractional seconds, e.g. `2024-07-21T20:02:24.995815902Z`.
  /// `ISO8601DateFormatter` treats `.withFractionalSeconds` as REQUIRED, not
  /// optional, hence the pair of formatters below.
  nonisolated(unsafe) private static let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return dateFormatter
  }()

  /// RFC3339 without fractional seconds, e.g. `2024-07-21T20:02:24Z`. Go's
  /// RFC3339 marshalling (our Navidrome fork) omits trailing-zero fractions, so
  /// most `created` / `played` values arrive in THIS shape and used to parse to
  /// nil under the fractional-seconds-only formatter.
  nonisolated(unsafe) private static let plainDateFormatter: ISO8601DateFormatter = {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]
    return dateFormatter
  }()

  /// Tolerant RFC3339 parsing: fractional seconds first (the stricter, more
  /// specific format), then plain. Both formatters are static because
  /// `ISO8601DateFormatter` construction is expensive and this runs once per
  /// date attribute per song across whole-library syncs.
  static func parseServerDate(_ rawValue: String) -> Date? {
    fractionalSecondsDateFormatter.date(from: rawValue)
      ?? plainDateFormatter.date(from: rawValue)
  }

  /// Merges the server's play data into the EXISTING local fields rather than
  /// adding Core Data columns (fork convention: no schema changes).
  ///
  /// * `playCount = max(local, server)`
  /// * `lastTimePlayed` (the `lastPlayedDate` column) `= later(local, server)`
  ///
  /// `AbstractPlayable.countPlayed()` bumps the local values the instant a song
  /// starts playing — including offline, on a bus — so those must never be
  /// clobbered by a server value that predates them. Taking the max/later in
  /// both directions means neither source can lose data: local plays stay
  /// visible immediately, and a later sync raises the floor with plays that
  /// happened on other clients.
  private func mergeServerPlayData(from attributeDict: [String: String]) {
    guard let songBuffer else { return }

    if let playCountTag = attributeDict["playCount"],
       let serverPlayCount = Int(playCountTag) {
      songBuffer.playCount = max(songBuffer.playCount, serverPlayCount)
    }

    if let playedTag = attributeDict["played"],
       let serverLastPlayedDate = Self.parseServerDate(playedTag) {
      if let localLastPlayedDate = songBuffer.lastTimePlayed {
        songBuffer.lastTimePlayed = max(localLastPlayedDate, serverLastPlayedDate)
      } else {
        songBuffer.lastTimePlayed = serverLastPlayedDate
      }
    }
  }

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    if elementName == "song" || elementName == "entry" || elementName == "child" || elementName ==
      "episode" {
      guard let songId = attributeDict["id"] else { return }
      let isDir = attributeDict["isDir"] ?? "false"
      guard let isDirBool = Bool(isDir), isDirBool == false else { return }

      if let prefetchedSong = prefetch.prefetchedSongDict[songId] {
        songBuffer = prefetchedSong
        songBuffer?.remoteStatus = .available
        guessedArtist = prefetchedSong.artist
        guessedAlbum = prefetchedSong.album
        guessedGenre = prefetchedSong.genre
      } else {
        songBuffer = library.createSong(account: account)
        prefetch.prefetchedSongDict[songId] = songBuffer
        songBuffer?.id = songId
        guessedArtist = nil
        guessedAlbum = nil
        guessedGenre = nil
      }
      playableBuffer = songBuffer

      if let artistId = attributeDict["artistId"] {
        if let guessedArtist, guessedArtist.id == artistId {
          songBuffer?.artist = guessedArtist
          songBuffer?.artist?.remoteStatus = .available
        } else if let prefetchedArtist = prefetch.prefetchedArtistDict[artistId] {
          songBuffer?.artist = prefetchedArtist
          songBuffer?.artist?.remoteStatus = .available
        } else if let artistName = attributeDict["artist"] {
          let artist = library.createArtist(account: account)
          prefetch.prefetchedArtistDict[artistId] = artist
          artist.id = artistId
          artist.name = artistName
          os_log(
            "Artist <%s> with id %s has been created",
            log: log,
            type: .error,
            artistName,
            artistId
          )
          songBuffer?.artist = artist
        }
      } else if let songBuffer = songBuffer, let artistName = attributeDict["artist"] {
        if let guessedArtist, guessedArtist.name == artistName {
          songBuffer.artist = guessedArtist
        } else if let prefetchedArtist = prefetch.prefetchedLocalArtistDict[artistName] {
          songBuffer.artist = prefetchedArtist
        } else {
          let artist = library.createArtist(account: account)
          prefetch.prefetchedLocalArtistDict[artistName] = artist
          artist.name = artistName
          songBuffer.artist = artist
          os_log("Local Artist <%s> has been created (no id)", log: log, type: .error, artistName)
        }
      }

      if let albumId = attributeDict["albumId"] {
        if let guessedAlbum, guessedAlbum.id == albumId {
          songBuffer?.album = guessedAlbum
          songBuffer?.album?.remoteStatus = .available
        } else if let prefetchedAlbum = prefetch.prefetchedAlbumDict[albumId] {
          songBuffer?.album = prefetchedAlbum
          songBuffer?.album?.remoteStatus = .available
        } else if let albumName = attributeDict["album"] {
          let album = library.createAlbum(account: account)
          prefetch.prefetchedAlbumDict[albumId] = album
          album.id = albumId
          album.name = albumName
          os_log(
            "Album <%s> with id %s has been created",
            log: log,
            type: .error,
            albumName,
            albumId
          )
          songBuffer?.album = album
        }
      }

      if let genreName = attributeDict["genre"] {
        if let guessedGenre, guessedGenre.name == genreName {
          songBuffer?.genre = guessedGenre
        } else if let prefetchedGenre = prefetch.prefetchedGenreDict[genreName] {
          songBuffer?.genre = prefetchedGenre
        } else {
          let genre = library.createGenre(account: account)
          prefetch.prefetchedGenreDict[genreName] = genre
          genre.name = genreName
          os_log("Genre <%s> has been created", log: log, type: .error, genreName)
          songBuffer?.genre = genre
        }
      }
      if let createdTag = attributeDict["created"] {
        songBuffer?.addedDate = Self.parseServerDate(createdTag)
      }
      mergeServerPlayData(from: attributeDict)
    }

    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "song" || elementName == "entry" || elementName == "child" || elementName ==
      "episode", songBuffer != nil {
      parsedCount += 1
      resetPlayableBuffer()
      if let song = songBuffer {
        parsedSongs.append(song)
      }
      songBuffer = nil
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
