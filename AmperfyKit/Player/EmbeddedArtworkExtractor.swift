//
//  EmbeddedArtworkExtractor.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 25.11.21.
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

import Foundation
@preconcurrency import ID3TagEditor

final class EmbeddedArtworkExtractor: Sendable {
  private let id3TagEditor = ID3TagEditor()
  private let fileManager = CacheFileManager.shared

  func extractEmbeddedArtwork(
    playableInfo: AbstractPlayableInfo,
    storage: AsyncCoreDataAccessWrapper
  ) async throws {
    let absFilePath: URL? = try await storage.performAndGet { asyncCompanion in
      let playable = AbstractPlayable(
        managedObject: asyncCompanion.context
          .object(with: playableInfo.objectID) as! AbstractPlayableMO
      )
      guard let relFilePath = playable.relFilePath else { return nil }
      return self.fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    }
    guard let absFilePath else { return }

    guard let id3Tag = try? id3TagEditor.read(from: absFilePath.path) else { return }
    let tagContentReader = ID3TagContentReader(id3Tag: id3Tag)
    let artworks = tagContentReader.attachedPictures()

    try await storage.perform { asyncCompanion in
      let playable = AbstractPlayable(
        managedObject: asyncCompanion.context
          .object(with: playableInfo.objectID) as! AbstractPlayableMO
      )

      // if there is a frontCover artwork take this as embedded artwork
      if let frontCoverArtwork = artworks.lazy.filter({ $0.type == .frontCover }).first,
         !frontCoverArtwork.picture.isEmpty {
        self.saveEmbeddedImageInLibrary(
          library: asyncCompanion.library,
          playable: playable,
          imageData: frontCoverArtwork.picture
        )
        // take the first other available artwork
      } else if let firstArtwork = artworks.lazy.first(where: { !$0.picture.isEmpty }) {
        self.saveEmbeddedImageInLibrary(
          library: asyncCompanion.library,
          playable: playable,
          imageData: firstArtwork.picture
        )
      }
    }
  }

  private func saveEmbeddedImageInLibrary(
    library: LibraryStorage,
    playable: AbstractPlayable,
    imageData: Data
  ) {
    guard let account = playable.account else { return }
    let embeddedArtwork = library.createEmbeddedArtwork(account: account)
    embeddedArtwork.owner = playable

    guard let relFilePath = fileManager.createRelPath(for: embeddedArtwork),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return }

    do {
      try fileManager.writeDataExcludedFromBackup(
        data: imageData,
        to: absFilePath,
        accountInfo: account.info
      )
      embeddedArtwork.relFilePath = relFilePath
    } catch {
      embeddedArtwork.relFilePath = nil
    }
    library.saveContext()
  }
}
