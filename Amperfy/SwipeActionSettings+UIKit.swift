//
//  SwipeActionSettings+UIKit.swift
//  Amperfy
//
//  UIImage property for SwipeActionType, moved from AmperfyKit during Sep-5.
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

extension SwipeActionType {
  @MainActor
  public var image: UIImage {
    switch self {
    case .insertUserQueue:
      return UIImage.userQueueInsert.withTintColor(.white)
    case .appendUserQueue:
      return UIImage.userQueueAppend.withTintColor(.white)
    case .insertContextQueue:
      return UIImage.contextQueueInsert.withTintColor(.white)
    case .appendContextQueue:
      return UIImage.contextQueueAppend.withTintColor(.white)
    case .download:
      return UIImage.download.withTintColor(.white)
    case .removeFromCache:
      return UIImage.trash.withTintColor(.white)
    case .addToPlaylist:
      return UIImage.playlist.withTintColor(.white)
    case .play:
      return UIImage.play.withTintColor(.white)
    case .playShuffled:
      return UIImage.shuffle.withTintColor(.white)
    case .insertPodcastQueue:
      return UIImage.podcastQueueInsert.withTintColor(.white)
    case .appendPodcastQueue:
      return UIImage.podcastQueueAppend.withTintColor(.white)
    case .favorite:
      return UIImage.heartFill.withTintColor(.white)
    }
  }
}
