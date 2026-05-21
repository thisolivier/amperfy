//
//  LibraryEntityImage.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 10.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import CoreData
import UIKit

extension LibraryEntityImage {
  // Cache should not be used between different instances -> iOS and Carplay
  static public func getImageToDisplayImmediately(
    libraryEntity: AbstractLibraryEntity,
    themePreference: ThemePreference,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> UIImage {
    ArtworkImageLoader.getImageToDisplayImmediately(
      libraryEntity: libraryEntity,
      themePreference: themePreference,
      artworkDisplayPreference: artworkDisplayPreference,
      useCache: useCache
    )
  }
}

// MARK: - LibraryEntityImage

@MainActor
public class LibraryEntityImage: RoundedImage {
  static private var cache: NSCache<NSString, UIImage> { ArtworkImageLoader.cache }

  private let amperKit: AmperKit

  private var entity: AbstractLibraryEntity?
  private var backupArtworkType: ArtworkType?
  private var accountNotificationHandler: AccountNotificationHandler?

  required public init?(coder: NSCoder) {
    self.amperKit = AmperKit.shared
    super.init(coder: coder)
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: amperKit.storage,
      notificationHandler: amperKit.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      amperKit.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: amperKit.getMeta(accountInfo).artworkDownloadManager
      )
      amperKit.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: amperKit.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  override public init(frame: CGRect) {
    self.amperKit = AmperKit.shared
    super.init(frame: .zero)
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: amperKit.storage,
      notificationHandler: amperKit.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      amperKit.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: amperKit.getMeta(accountInfo).artworkDownloadManager
      )
      amperKit.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: amperKit.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  public func display(entity: AbstractLibraryEntity) {
    self.entity = entity
    backupArtworkType = entity.getDefaultArtworkType()
    refresh()
  }

  public func displayAndUpdate(entity: AbstractLibraryEntity) {
    guard self.entity != entity else { return }

    display(entity: entity)
    if let artwork = entity.artwork, let accountInfo = entity.account?.info {
      amperKit.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
  }

  internal func display(image: UIImage) {
    self.image = image
    entity = nil
  }

  public func display(artworkType: ArtworkType) {
    backupArtworkType = artworkType
    entity = nil
    refresh()
  }

  private var placeholderImage: UIImage {
    var theme = amperKit.storage.settings.accounts.activeSetting.read.themePreference
    if let accountInfo = entity?.account?.info {
      theme = amperKit.storage.settings.accounts.getSetting(accountInfo).read.themePreference
    }
    return UIImage.getGeneratedArtwork(
      theme: theme,
      artworkType: backupArtworkType ?? .song
    )
  }

  private var entityImagePathToDisplay: String? {
    var artworkDisplayPreference = amperKit.storage.settings.accounts.activeSetting.read
      .artworkDisplayPreference
    if let accountInfo = entity?.account?.info {
      artworkDisplayPreference = amperKit.storage.settings.accounts.getSetting(accountInfo).read
        .artworkDisplayPreference
    }
    return entity?.imagePath(
      setting: artworkDisplayPreference
    )
  }

  private func refresh() {
    let imagePathToDisplay = entityImagePathToDisplay

    if let imagePathToDisplay,
       let cachedImg = Self.cache.object(forKey: imagePathToDisplay as NSString) {
      image = cachedImg
      return
    }

    image = placeholderImage
    guard let imagePathToDisplay else { return }

    Task.detached(priority: .high) { [weak self] in
      await self?.loadImageAndCacheIt(imagePath: imagePathToDisplay)
    }
  }

  @concurrent
  private func loadImageAndCacheIt(
    imagePath: String
  ) async {
    guard !Task.isCancelled else { return }
    let loadedImage = UIImage(contentsOfFile: imagePath)
    let readyImage = await loadedImage?.byPreparingForDisplay()
    guard !Task.isCancelled else { return }
    Task { @MainActor [weak self] in
      guard let self, let readyImage else { return }
      Self.cache.setObject(readyImage, forKey: imagePath as NSString)
      refresh()
    }
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification), let entity
    else { return }
    if let playable = entity as? AbstractPlayable,
       playable.uniqueID == downloadNotification.id, let accountInfo = playable.account?.info {
      Task { @MainActor in
        guard let imagePath = entity.imagePath(
          setting: amperKit.storage.settings.accounts.getSetting(accountInfo).read
            .artworkDisplayPreference
        ) else { return }
        await self.loadImageAndCacheIt(
          imagePath: imagePath
        )
      }
    }
    if let artwork = entity.artwork,
       artwork.uniqueID == downloadNotification.id, let accountInfo = artwork.account?.info {
      Task { @MainActor in
        guard let imagePath = entity.imagePath(
          setting: amperKit.storage.settings.accounts.getSetting(accountInfo).read
            .artworkDisplayPreference
        ) else { return }
        await self.loadImageAndCacheIt(
          imagePath: imagePath
        )
      }
    }
  }
}
