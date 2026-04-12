//
//  HomeSection.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 26.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

public enum HomeSection: Int, Sendable, CaseIterable, Codable {
  // add new section always at the end to keep the Int consitent
  case lastTimePlayedPlaylists
  case recentlyPlayedAlbums
  case newestAlbums
  case randomAlbums
  case newestPodcastEpisodes
  case podcasts
  case radios
  case randomArtists
  case randomGenres
  case randomSongs
  case recentTracks
  case favouriteAlbums
  case favouriteArtists
  case favouritePlaylists

  static let defaultValue: [HomeSection] = [
    .randomAlbums,
    .recentlyPlayedAlbums,
    .lastTimePlayedPlaylists,
    .newestAlbums,
    .recentTracks,
    .favouriteAlbums,
    .favouriteArtists,
    .favouritePlaylists,
  ]

  public var title: String {
    switch self {
    case .recentlyPlayedAlbums: return "Recently Played Albums"
    case .newestAlbums: return "Newest Albums"
    case .randomAlbums: return "Random Albums"
    case .lastTimePlayedPlaylists: return "Recently Played Playlists"
    case .newestPodcastEpisodes: return "Newest Podcast Episodes"
    case .podcasts: return "Podcasts"
    case .radios: return "Radios"
    case .randomArtists: return "Random Artists"
    case .randomGenres: return "Random Genres"
    case .randomSongs: return "Random Songs"
    case .recentTracks: return "Recently Added Tracks"
    case .favouriteAlbums: return "Favourite Albums"
    case .favouriteArtists: return "Favourite Artists"
    case .favouritePlaylists: return "Favourite Playlists"
    }
  }

  public static func create(fromTitle: String) -> HomeSection? {
    allCases.first(where: { $0.title == fromTitle })
  }

  public var isRandomSection: Bool {
    switch self {
    case .recentlyPlayedAlbums: return false
    case .newestAlbums: return false
    case .randomAlbums: return true
    case .lastTimePlayedPlaylists: return false
    case .newestPodcastEpisodes: return false
    case .podcasts: return false
    case .radios: return false
    case .randomArtists: return true
    case .randomGenres: return true
    case .randomSongs: return true
    case .recentTracks: return false
    case .favouriteAlbums: return false
    case .favouriteArtists: return false
    case .favouritePlaylists: return false
    }
  }
}
