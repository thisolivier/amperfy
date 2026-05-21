//
//  ArtworkImageLoader.swift
//  AmperfyKit
//
//  Created by Olivier on 20.05.26.
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

@MainActor
public enum ArtworkImageLoader {
  public nonisolated(unsafe) static let cache: NSCache<NSString, NSData> = NSCache()

  /// Returns image data for the given entity, checking the in-memory cache first.
  /// Returns nil if no artwork is found (caller should use a generated placeholder).
  public static func getImageDataToDisplayImmediately(
    libraryEntity: AbstractLibraryEntity,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> Data? {
    if let artworkImagePath = libraryEntity.imagePath(
      setting: artworkDisplayPreference
    ) {
      if useCache, let cachedData = cache.object(forKey: artworkImagePath as NSString) {
        return cachedData as Data
      } else if let fileURL = Bundle.main.url(forResource: artworkImagePath, withExtension: nil),
                let data = try? Data(contentsOf: fileURL) {
        cache.setObject(data as NSData, forKey: artworkImagePath as NSString)
        return data
      }
    }
    return nil
  }
}
