//
//  SsAlbumParserDelegate.swift
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

class SsAlbumParserDelegate: SsXmlLibWithArtworkParser {
  var guessedArtist: Artist?
  var guessedGenre: Genre?
  var parsedAlbums = [Album]()
  private var albumBuffer: Album?

  /// OpenSubsonic `releaseTypes` nested-element values collected for the
  /// current album. Each `<releaseTypes>Album</releaseTypes>` child appends one
  /// entry. Joined, lowercased, and stored on the album at `didEndElement` for
  /// the closing `</album>` tag.
  private var releaseTypesNestedParts: [String] = []
  /// Set to `true` while the parser is inside a `<releaseTypes>` child of the
  /// current album so that `foundCharacters` knows to accumulate text.
  private var isInsideReleaseTypesElement = false
  /// Text buffer for the currently open `<releaseTypes>` child. XMLParser may
  /// deliver characters in multiple chunks, so we accumulate before trimming.
  private var releaseTypesCharBuffer = ""

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )

    if elementName == "album" {
      guard let albumId = attributeDict["id"] else { return }

      // Reset per-album nested-element accumulator. Must happen before any
      // potential early return from the attribute-form branch below so that
      // a fresh album always starts with a clean buffer.
      releaseTypesNestedParts = []

      if let prefetchedAlbum = prefetch.prefetchedAlbumDict[albumId] {
        albumBuffer = prefetchedAlbum
        guessedArtist = prefetchedAlbum.artist
        guessedGenre = prefetchedAlbum.genre
      } else {
        albumBuffer = library.createAlbum(account: account)
        prefetch.prefetchedAlbumDict[albumId] = albumBuffer
        albumBuffer?.id = albumId
        guessedArtist = nil
        guessedGenre = nil
      }
      albumBuffer?.remoteStatus = .available

      // OpenSubsonic attribute-form of releaseTypes (some servers emit this
      // instead of or in addition to nested <releaseTypes> child elements).
      // Nested form, if present, will override at didEndElement("album").
      if let attributeReleaseTypes = attributeDict["releaseTypes"] {
        let trimmed = attributeReleaseTypes
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if !trimmed.isEmpty {
          albumBuffer?.releaseType = trimmed
        }
      }

      if let attributeAlbumtName = attributeDict["name"] {
        albumBuffer?.name = attributeAlbumtName
      }
      if let attributeCoverArt = attributeDict["coverArt"] {
        albumBuffer?.artwork = parseArtwork(id: attributeCoverArt)
      }
      albumBuffer?.rating = Int(attributeDict["userRating"] ?? "0") ?? 0
      albumBuffer?.isFavorite = attributeDict["starred"] != nil
      if let attributeYear = attributeDict["year"], let year = Int(attributeYear) {
        albumBuffer?.year = year
      }
      if let attributeSongCount = attributeDict["songCount"],
         let songCount = Int(attributeSongCount) {
        // Server-side song set changed since the last full song sync (e.g. a track
        // was deleted via an admin tool): force a song-level re-sync so the per-song
        // diff in sync(album:) can prune removed songs. Without this, an album is
        // song-synced at most once and server deletions inside it are never noticed.
        if let albumBuffer, albumBuffer.isSongsMetaDataSynced,
           albumBuffer.remoteSongCount != songCount {
          albumBuffer.isSongsMetaDataSynced = false
        }
        albumBuffer?.remoteSongCount = songCount
      }
      if let attributeDuration = attributeDict["duration"], let duration = Int(attributeDuration) {
        albumBuffer?.remoteDuration = duration
      }

      if let artistId = attributeDict["artistId"] {
        if let guessedArtist, guessedArtist.id == artistId {
          albumBuffer?.artist = guessedArtist
        } else if let prefetchedArtist = prefetch.prefetchedArtistDict[artistId] {
          albumBuffer?.artist = prefetchedArtist
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
          albumBuffer?.artist = artist
        }
      }

      if let genreName = attributeDict["genre"] {
        if let guessedGenre, guessedGenre.name == genreName {
          albumBuffer?.genre = guessedGenre
        } else if let prefetchedGenre = prefetch.prefetchedGenreDict[genreName] {
          albumBuffer?.genre = prefetchedGenre
        } else {
          let genre = library.createGenre(account: account)
          prefetch.prefetchedGenreDict[genreName] = genre
          genre.name = genreName
          os_log("Genre <%s> has been created", log: log, type: .error, genreName)
          albumBuffer?.genre = genre
        }
      }
    } else if elementName == "releaseTypes", albumBuffer != nil {
      // OpenSubsonic nested-element form: one <releaseTypes>Album</releaseTypes>
      // child per release type. We accumulate the text via foundCharacters and
      // commit in the matching didEndElement handler below.
      isInsideReleaseTypesElement = true
      releaseTypesCharBuffer = ""
    }
  }

  override func parser(_ parser: XMLParser, foundCharacters string: String) {
    if isInsideReleaseTypesElement {
      releaseTypesCharBuffer.append(string)
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "album":
      // Nested-element form wins over attribute-form: if we collected any
      // <releaseTypes> children, join them with ", " (the same separator
      // a comma-delimited attribute would use) so the predicate CONTAINS[c]
      // checks stay uniform across both wire formats.
      if !releaseTypesNestedParts.isEmpty {
        albumBuffer?.releaseType = releaseTypesNestedParts.joined(separator: ", ")
      }
      releaseTypesNestedParts = []
      parsedCount += 1
      if let album = albumBuffer {
        parsedAlbums.append(album)
      }
      albumBuffer = nil
    case "releaseTypes":
      if isInsideReleaseTypesElement {
        let trimmed = releaseTypesCharBuffer
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if !trimmed.isEmpty {
          releaseTypesNestedParts.append(trimmed)
        }
        releaseTypesCharBuffer = ""
        isInsideReleaseTypesElement = false
      }
    default:
      break
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
