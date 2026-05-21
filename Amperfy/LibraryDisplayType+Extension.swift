//
//  LibraryDisplayType+Extension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 28.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import UIKit

extension LibraryDisplayType {
  public var image: UIImage {
    switch self {
    case .artists:
      return UIImage.artist
    case .albums:
      return UIImage.album
    case .songs:
      return UIImage.musicalNotes
    case .genres:
      return UIImage.genre
    case .directories:
      return UIImage.folder
    case .playlists:
      return UIImage.playlist
    case .podcasts:
      return UIImage.podcast
    case .downloads:
      return UIImage.download
    case .favoriteSongs:
      return UIImage.heartFill
    case .favoriteAlbums:
      return UIImage.heartFill
    case .favoriteArtists:
      return UIImage.heartFill
    case .newestAlbums:
      return UIImage.albumNewest
    case .recentAlbums:
      return UIImage.albumRecent
    case .radios:
      return UIImage.radio
    case .completeAlbums:
      return UIImage.album
    }
  }

  public func controller(account: Account, settings: AmperfySettings) -> UIViewController {
    switch self {
    case .artists:
      return AppStoryboard.Main.segueToArtists(account: account)
    case .albums:
      return AppStoryboard.Main.createAlbumsVC(
        account: account,
        style: settings.user.albumsStyleSetting,
        category: .all
      )
    case .songs:
      return AppStoryboard.Main.segueToSongs(account: account)
    case .genres:
      return AppStoryboard.Main.segueToGenres(account: account)
    case .directories:
      return AppStoryboard.Main.segueToMusicFolders(account: account)
    case .playlists:
      return AppStoryboard.Main.segueToPlaylists(account: account)
    case .podcasts:
      return AppStoryboard.Main.segueToPodcasts(account: account)
    case .downloads:
      return AppStoryboard.Main.segueToDownloads(account: account)
    case .favoriteSongs:
      return AppStoryboard.Main.segueToFavoriteSongs(account: account)
    case .favoriteAlbums:
      return AppStoryboard.Main.createAlbumsVC(
        account: account,
        style: settings.user.albumsStyleSetting,
        category: .favorites
      )
    case .favoriteArtists:
      return AppStoryboard.Main.segueToFavoriteArtists(account: account)
    case .newestAlbums:
      return AppStoryboard.Main.createAlbumsVC(
        account: account,
        style: settings.user.albumsStyleSetting,
        category: .newest
      )
    case .recentAlbums:
      return AppStoryboard.Main.createAlbumsVC(
        account: account,
        style: settings.user.albumsStyleSetting,
        category: .recent
      )
    case .radios:
      return AppStoryboard.Main.segueToRadios(account: account)
    case .completeAlbums:
      return AppStoryboard.Main.createAlbumsVC(
        account: account,
        style: settings.user.albumsStyleSetting,
        category: .all,
        wholeAlbumsOnly: true
      )
    }
  }
}
