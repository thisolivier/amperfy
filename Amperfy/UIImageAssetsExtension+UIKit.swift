//
//  UIImageAssetsExtension+UIKit.swift
//  Amperfy
//
//  Moved from AmperfyKit/Assets/UIImageAssetsExtension.swift during Sep-5 UIKit removal.
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

// MARK: - UIUserInterfaceStyle bridging

extension UIUserInterfaceStyle {
  public var asModeType: LightDarkModeType {
    switch self {
    case .unspecified:
      return .light
    case .light:
      return .light
    case .dark:
      return .dark
    @unknown default:
      return .light
    }
  }
}

// MARK: - AmperfyImage + UIImage

extension AmperfyImage {
  @MainActor
  public var asUIImage: UIImage {
    if !assetName.isEmpty {
      return UIImage(named: assetName) ?? UIImage()
    } else {
      return UIImage.create(systemName: systemName)
    }
  }
}

// MARK: - UIImage asset extensions

@MainActor
extension UIImage {
  public static func symbolImageSize(scale: UIImage.SymbolScale) -> CGSize {
    let config = UIImage.SymbolConfiguration(scale: scale)
    let image = UIImage(systemName: AmperfyImage.plus.systemName, withConfiguration: config)!
    return image.size
  }

  public static let airplayaudio = UIImage.create(systemName: AmperfyImage.airplayaudio.systemName)
  public static let album = UIImage.create(systemName: AmperfyImage.album.systemName)
  /// Gigs library tab icon (fork 2026-07). A system symbol used directly since
  /// Gigs isn't part of the upstream AmperfyImage catalog.
  public static let gigs = UIImage.create(systemName: "music.mic")
  /// Smart Playlists library row. `wand.and.stars` rather than the spec's
  /// `sparkles` suggestion because `sparkles` is already the What's New /
  /// generative-art icon elsewhere in the app.
  public static let smartPlaylists = UIImage.create(systemName: "wand.and.stars")
  public static let antenna = UIImage.create(systemName: AmperfyImage.antenna.systemName)
  public static let artist = UIImage.create(systemName: AmperfyImage.artist.systemName)
  public static let appIcon = UIImage.create("Icon-1024")
  public static let appIconTemplate = UIImage.create("Icon-monocolor")
    .withRenderingMode(.alwaysTemplate)
  public static let arrowRight = UIImage.create(systemName: AmperfyImage.arrowRight.systemName)
  public static let arrowTurnUp = UIImage.create(systemName: AmperfyImage.arrowTurnUp.systemName)
  public static let audioVisualizer = UIImage
    .create(systemName: AmperfyImage.audioVisualizer.systemName)
  public static let backwardFill = UIImage.create(systemName: AmperfyImage.backwardFill.systemName)
  public static let backwardMenu = UIImage.create(systemName: AmperfyImage.backwardMenu.systemName)
  public static let ban = UIImage.create(systemName: AmperfyImage.ban.systemName)
  public static let bars = UIImage.create(systemName: AmperfyImage.bars.systemName)
  public static let bell = UIImage.create(systemName: AmperfyImage.bell.systemName)
  public static let cache = download
  public static let cancleDownloads = UIImage
    .create(systemName: AmperfyImage.cancleDownloads.systemName)
  public static let check = UIImage.create(systemName: AmperfyImage.check.systemName)
  public static let circle = UIImage.create(systemName: AmperfyImage.circle.systemName)
  public static let clear = UIImage.create(systemName: AmperfyImage.clear.systemName)
  public static let clipboard = UIImage.create(systemName: AmperfyImage.clipboard.systemName)
  public static let clock = UIImage.create(systemName: AmperfyImage.clock.systemName)
  public static let cloudX = UIImage.create(systemName: AmperfyImage.cloudX.systemName)
  public static let currentSongMenu = UIImage
    .create(systemName: AmperfyImage.currentSongMenu.systemName)
  public static let display = UIImage.create(systemName: AmperfyImage.display.systemName)
  public static let doc = UIImage.create(systemName: AmperfyImage.doc.systemName)
  public static let documents = UIImage.create(systemName: AmperfyImage.documents.systemName)
  public static let download = UIImage.create(systemName: AmperfyImage.download.systemName)
  public static let ellipsis = UIImage.create(systemName: AmperfyImage.ellipsis.systemName)
  public static let equalizer = UIImage.create(systemName: AmperfyImage.equalizer.systemName)
  public static let exclamation = UIImage.create(systemName: AmperfyImage.exclamation.systemName)
  public static let filter = UIImage.create(systemName: AmperfyImage.filter.systemName)
  public static let flag = UIImage.create(systemName: AmperfyImage.flag.systemName)
  public static let followLink = UIImage.create(systemName: AmperfyImage.followLink.systemName)
  public static let folder = UIImage.create(systemName: AmperfyImage.folder.systemName)
  public static let forwardFill = UIImage.create(systemName: AmperfyImage.forwardFill.systemName)
  public static let forwardMenu = UIImage.create(systemName: AmperfyImage.forwardMenu.systemName)
  public static let genre = UIImage.create(systemName: AmperfyImage.genre.systemName)
  public static let goBackward15 = UIImage.create(systemName: AmperfyImage.goBackward15.systemName)
  public static let goForward30 = UIImage.create(systemName: AmperfyImage.goForward30.systemName)
  public static let grid = UIImage.create(systemName: AmperfyImage.grid.systemName)
  public static let hammer = UIImage.create(systemName: AmperfyImage.hammer.systemName)
  public static let heartEmpty = UIImage.create(systemName: AmperfyImage.heartEmpty.systemName)
  public static let heartFill = UIImage.create(systemName: AmperfyImage.heartFill.systemName)
  public static let heartSlash = UIImage.create(systemName: AmperfyImage.heartSlash.systemName)
  public static let home = UIImage.create(systemName: AmperfyImage.home.systemName)
  public static let info = UIImage.create(systemName: AmperfyImage.info.systemName)
  public static let isSelected = UIImage.create(systemName: AmperfyImage.isSelected.systemName)
  public static let listBullet = UIImage.create(systemName: AmperfyImage.listBullet.systemName)
  public static let login = UIImage.create(systemName: AmperfyImage.login.systemName)
  public static let lyrics = UIImage.create(systemName: AmperfyImage.lyrics.systemName)
  public static let miniPlayer = UIImage.create(systemName: AmperfyImage.miniPlayer.systemName)
  public static let minus = UIImage.create(systemName: AmperfyImage.minus.systemName)
  public static let musicLibrary = UIImage.create(systemName: AmperfyImage.musicLibrary.systemName)
  public static let musicalNotes = UIImage.create(systemName: AmperfyImage.musicalNotes.systemName)
  public static let pause = UIImage.create(systemName: AmperfyImage.pause.systemName)
  public static let pauseMenu = UIImage.create(systemName: AmperfyImage.pauseMenu.systemName)
  public static let password = UIImage.create(systemName: AmperfyImage.password.systemName)
  public static let person = UIImage.create(systemName: AmperfyImage.person.systemName)
  public static let photo = UIImage.create(systemName: AmperfyImage.photo.systemName)
  public static let play = UIImage.create(systemName: AmperfyImage.play.systemName)
  public static let playCircle = UIImage.create(systemName: AmperfyImage.playCircle.systemName)
  public static let playMenu = UIImage.create(systemName: AmperfyImage.playMenu.systemName)
  public static let playbackRate = UIImage.create(systemName: AmperfyImage.playbackRate.systemName)
  public static let playlist = UIImage.create(systemName: AmperfyImage.playlist.systemName)
  public static let playlistDisplayStyle = UIImage
    .create(systemName: AmperfyImage.playlistDisplayStyle.systemName)
  public static let playlistPlus = UIImage.create(systemName: AmperfyImage.playlistPlus.systemName)
  public static let playlistX = UIImage.create(systemName: AmperfyImage.playlistX.systemName)
  public static let plus = UIImage.create(systemName: AmperfyImage.plus.systemName)
  public static let plusCircle = UIImage.create(systemName: AmperfyImage.plusCircle.systemName)
  public static let radio = UIImage.create(systemName: AmperfyImage.radio.systemName)
  public static let redo = UIImage.create(systemName: AmperfyImage.redo.systemName)
  public static let refresh = UIImage.create(systemName: AmperfyImage.refresh.systemName)
  public static let repeatAll = UIImage.create(systemName: AmperfyImage.repeatAll.systemName)
  public static let repeatMenu = UIImage.create(systemName: AmperfyImage.repeatMenu.systemName)
  public static let repeatOff = UIImage.create(systemName: AmperfyImage.repeatOff.systemName)
  public static let repeatOne = UIImage.create(systemName: AmperfyImage.repeatOne.systemName)
  public static let resize = UIImage.create(systemName: AmperfyImage.resize.systemName)
  public static let search = UIImage.create(systemName: AmperfyImage.search.systemName)
  public static let server = UIImage.create(systemName: AmperfyImage.server.systemName)
  public static let serverUrl = UIImage.create(systemName: AmperfyImage.serverUrl.systemName)
  public static let settings = UIImage.create(systemName: AmperfyImage.settings.systemName)
  public static let shuffle = UIImage.create(systemName: AmperfyImage.shuffle.systemName)
  public static let instantMix = UIImage.create(systemName: AmperfyImage.instantMix.systemName)
  public static let shuffleMenu = UIImage.create(systemName: AmperfyImage.shuffleMenu.systemName)
  public static let skipBackward10 = UIImage
    .create(systemName: AmperfyImage.skipBackward10.systemName)
  public static let skipBackward15 = UIImage
    .create(systemName: AmperfyImage.skipBackward15.systemName)
  public static let skipBackwardMenu = UIImage
    .create(systemName: AmperfyImage.skipBackwardMenu.systemName)
  public static let skipForward10 = UIImage
    .create(systemName: AmperfyImage.skipForward10.systemName)
  public static let skipForward30 = UIImage
    .create(systemName: AmperfyImage.skipForward30.systemName)
  public static let skipForwardMenu = UIImage
    .create(systemName: AmperfyImage.skipForwardMenu.systemName)
  public static let sleep = UIImage.create(systemName: AmperfyImage.sleep.systemName)
  public static let sleepFill = UIImage.create(systemName: AmperfyImage.sleepFill.systemName)
  public static let sort = UIImage.create(systemName: AmperfyImage.sort.systemName)
  public static let sparkles = UIImage.create(systemName: AmperfyImage.sparkles.systemName)
  public static let squareArrow = UIImage.create(systemName: AmperfyImage.squareArrow.systemName)
  public static let starEmpty = UIImage.create(systemName: AmperfyImage.starEmpty.systemName)
  public static let starFill = UIImage.create(systemName: AmperfyImage.starFill.systemName)
  public static let starSlash = UIImage.create(systemName: AmperfyImage.starSlash.systemName)
  public static let startDownload = UIImage
    .create(systemName: AmperfyImage.startDownload.systemName)
  public static let stop = UIImage.create(systemName: AmperfyImage.stop.systemName)
  public static let stopMenu = UIImage.create(systemName: AmperfyImage.stopMenu.systemName)
  public static let trash = UIImage.create(systemName: AmperfyImage.trash.systemName)
  public static let triangleDown = UIImage.create(systemName: AmperfyImage.triangleDown.systemName)
  public static let unSelected = UIImage.create(systemName: AmperfyImage.unSelected.systemName)
  public static let userCircleCheckmark = UIImage
    .create(systemName: AmperfyImage.userCircleCheckmark.systemName)
  public static let userCirclePlus = UIImage
    .create(systemName: AmperfyImage.userCirclePlus.systemName)
  public static let userPerson = UIImage.create(systemName: AmperfyImage.userPerson.systemName)
  public static let volumeMax = UIImage.create(systemName: AmperfyImage.volumeMax.systemName)
  public static let volumeMin = UIImage.create(systemName: AmperfyImage.volumeMin.systemName)
  public static let xmark = UIImage.create(systemName: AmperfyImage.xmark.systemName)

  /// Asset symbol generation is enabled by default for both new and old projects but can be disabled by setting the build setting "Generate Asset Symbols" (ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS) to NO.
  #if false
    public static let podcast = UIImage.create("podcast").withTintColor(.defaultBlue)
    public static let albumNewest = UIImage.create("album_newest")
    public static let albumRecent = UIImage.create("album_recent")
    public static let userQueueInsert = UIImage
      .create("user_queue_insert")
    public static let userQueueAppend = UIImage
      .create("user_queue_append")
    public static let contextQueueInsert = UIImage
      .create("context_queue_insert")
    public static let contextQueueAppend = UIImage
      .create("context_queue_append")
  #endif
  public static let podcastEpisode: UIImage = podcast
  public static let podcastQueueInsert = contextQueueInsert
  public static let podcastQueueAppend = contextQueueAppend
  public static func userCircle(withConfiguration: UIImage.SymbolConfiguration? = nil) -> UIImage {
    UIImage(systemName: AmperfyImage.account.systemName, withConfiguration: withConfiguration) ??
      UIImage()
  }

  public static func getGeneratedArtwork(
    theme: ThemePreference,
    artworkType: ArtworkType
  )
    -> UIImage {
    let resourceName = "\(theme.description)\(artworkType.description)"
    return UIImage(imageLiteralResourceName: resourceName)
  }

  public static func generateArtwork(
    theme: ThemePreference,
    lightDarkMode: LightDarkModeType,
    artworkType: ArtworkType
  )
    -> UIImage {
    var generatedArtwork: UIImage?
    switch artworkType {
    case .album, .artist, .folder, .genre, .podcast, .radio:
      generatedArtwork = UIImage.createArtwork(
        with: artworkType.image.asUIImage,
        iconSizeType: .big,
        theme: theme,
        lightDarkMode: lightDarkMode
      )
    case .podcastEpisode, .song:
      generatedArtwork = UIImage.createArtwork(
        with: artworkType.image.asUIImage,
        iconSizeType: .small,
        theme: theme,
        lightDarkMode: lightDarkMode
      )
    case .playlist:
      generatedArtwork = UIImage.createArtwork(
        with: UIImage.playlist,
        iconSizeType: .small,
        theme: theme,
        lightDarkMode: lightDarkMode,
        switchColors: true
      )
    }
    return generatedArtwork ?? UIImage()
  }

  static func create(_ named: String) -> UIImage {
    UIImage(named: named) ?? UIImage()
  }

  static func create(systemName: String) -> UIImage {
    UIImage(systemName: systemName) ?? UIImage()
  }

  public static func createArtwork(
    with image: UIImage,
    iconSizeType: ArtworkIconSizeType,
    theme: ThemePreference,
    lightDarkMode: LightDarkModeType,
    switchColors: Bool = false
  )
    -> UIImage {
    let artworkSize = ArtworkIconSizeType.defaultSize
    let size = CGSize(width: artworkSize, height: artworkSize)
    let grayScale: CGFloat = lightDarkMode == .light ? 0.85 : 0.15
    let artworkBackgroundColor = UIColor(
      red: grayScale,
      green: grayScale,
      blue: grayScale,
      alpha: 1
    )
    let imageTintColor = !switchColors ? theme.asColor : artworkBackgroundColor
    let backgroundColor = switchColors ? theme.asColor : artworkBackgroundColor
    let inset = iconSizeType.rawValue
    let tintedImage = image.withTintColor(imageTintColor, renderingMode: .alwaysOriginal)

    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      backgroundColor.setFill()
      let cornerRadius: CGFloat = 5.0
      let backgroundPath = UIBezierPath(
        roundedRect: CGRect(origin: .zero, size: size),
        cornerRadius: cornerRadius
      )
      backgroundPath.fill()

      let imageRect = CGRect(
        x: inset, y: inset,
        width: artworkSize - 2 * inset, height: artworkSize - 2 * inset
      )
      tintedImage.draw(in: imageRect)
    }
  }

  private static func createEmptyImage(with size: CGSize) -> UIImage? {
    UIGraphicsBeginImageContext(size)
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
  }

  public static func numberToImage(number: Int) -> UIImage {
    let fontSize = 40.0
    let textFont = UIFont(name: "Helvetica Bold", size: fontSize)!

    let image = createEmptyImage(with: CGSize(width: 100.0, height: 100.0)) ?? UIImage()
    let scale = UITraitCollection.current.displayScale
    UIGraphicsBeginImageContextWithOptions(image.size, false, scale)

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center

    let textFontAttributes = [
      NSAttributedString.Key.font: textFont,
      NSAttributedString.Key.paragraphStyle: paragraphStyle,
      NSAttributedString.Key.foregroundColor: UIColor.lightGray,
    ] as [NSAttributedString.Key: Any]
    image.draw(in: CGRect(origin: CGPoint.zero, size: image.size))

    let textPoint = CGPoint(x: 0.0, y: 50.0 - (fontSize / 2))
    let rect = CGRect(origin: textPoint, size: image.size)
    number.description.draw(in: rect, withAttributes: textFontAttributes)

    let newImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return newImage!
  }

  public func styleForNavigationBar(pointSize: CGFloat, tintColor: UIColor) -> UIImage {
    let navBarSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: pointSize)
    let img = applyingSymbolConfiguration(navBarSymbolConfiguration) ?? UIImage()
    return img.withTintColor(tintColor)
  }
}
