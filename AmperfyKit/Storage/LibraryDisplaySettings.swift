//
//  LibraryDisplaySettings.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

// MARK: - LibraryDisplayType

@MainActor
public enum LibraryDisplayType: Int, CaseIterable, Sendable {
  case artists = 0
  case albums = 1
  case songs = 2
  case genres = 3
  case directories = 4
  case playlists = 5
  case podcasts = 6
  case downloads = 7
  case favoriteSongs = 8
  case favoriteAlbums = 9
  case favoriteArtists = 10
  // case recentSongs = 11 not used anymore
  case newestAlbums = 12
  case recentAlbums = 13
  case radios = 14
  case completeAlbums = 15
  case gigs = 16
  case smartPlaylists = 17

  public static func createByDisplayName(name: String) -> LibraryDisplayType? {
    .allCases.first {
      $0.displayName == name
    }
  }

  public var displayName: String {
    switch self {
    case .artists:
      return "Artists"
    case .albums:
      return "Albums"
    case .songs:
      return "Songs"
    case .genres:
      return "Genres"
    case .directories:
      return "Directories"
    case .playlists:
      return "Playlists"
    case .podcasts:
      return "Podcasts"
    case .downloads:
      return "Downloads"
    case .favoriteSongs:
      return "Favorite Songs"
    case .favoriteAlbums:
      return "Favorite Albums"
    case .favoriteArtists:
      return "Favorite Artists"
    case .newestAlbums:
      return "Newest Albums"
    case .recentAlbums:
      return "Recently Played Albums"
    case .radios:
      return "Radios"
    case .completeAlbums:
      return "Complete Albums"
    case .gigs:
      return "Gigs"
    case .smartPlaylists:
      return "Smart Playlists"
    }
  }
}

// MARK: - LibraryDisplaySettings

public struct LibraryDisplaySettings: Sendable, Codable {
  public var combined: [[LibraryDisplayType]]

  public var inUse: [LibraryDisplayType] {
    combined[0]
  }

  public var notUsed: [LibraryDisplayType] {
    combined[1]
  }

  private enum CodingKeys: String, CodingKey {
    case combined
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let encodedCombined = combined.map { $0.map { $0.rawValue } }
    try container.encode(encodedCombined, forKey: .combined)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCombined = try container.decode([[Int]].self, forKey: .combined)

    let mapped: [[LibraryDisplayType]] = decodedCombined.map { group in
      group.compactMap { LibraryDisplayType(rawValue: $0) }
    }

    if mapped.count == 2 {
      self.combined = mapped
    } else if let first = mapped.first {
      // If only one group present, treat it as inUse and compute notUsed
      self = LibraryDisplaySettings(inUse: first)
    } else {
      // Fallback to defaults if decoding produced no valid entries
      self = LibraryDisplaySettings(inUse: [])
    }
    migrateCompleteAlbums()
  }

  /// One-time migration: if .completeAlbums is missing from both inUse and
  /// notUsed, insert it where .albums was (replacing it in inUse, or at the
  /// start of inUse if .albums wasn't present). Existing users whose saved
  /// settings predate the completeAlbums case will hit this path.
  private mutating func migrateCompleteAlbums() {
    let allKnown = combined.flatMap { $0 }
    guard !allKnown.contains(.completeAlbums) else { return }

    var inUseList = combined[0]
    var notUsedList = combined[1]

    if let albumsIndex = inUseList.firstIndex(of: .albums) {
      // Replace .albums with .completeAlbums at the same position
      inUseList[albumsIndex] = .completeAlbums
      // Move .albums to notUsed
      notUsedList.append(.albums)
    } else {
      // .albums wasn't in inUse — just add .completeAlbums to inUse
      inUseList.insert(.completeAlbums, at: min(1, inUseList.count))
    }
    notUsedList.removeAll { $0 == .completeAlbums }
    combined = [inUseList, notUsedList.sorted(by: { $0.rawValue < $1.rawValue })]
  }

  public func isVisible(libraryType: LibraryDisplayType) -> Bool {
    inUse.contains(where: { $0 == libraryType })
  }

  public init(inUse: [LibraryDisplayType]) {
    let notUsedSet = Set(LibraryDisplayType.allCases).subtracting(Set(inUse))
    self.combined = [inUse, Array(notUsedSet).sorted(by: { $0.rawValue < $1.rawValue })]
  }

  public static var defaultSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .artists,
        .completeAlbums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        .favoriteSongs,
        .directories,
        .playlists,
        .podcasts,
        .radios,
        .gigs,
        .smartPlaylists,
      ]
    )
  }

  public static var addToPlaylistSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .genres,
        .artists,
        .favoriteArtists,
        .albums,
        .favoriteAlbums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        .favoriteSongs,
        .directories,
        .playlists,
      ]
    )
  }
}
