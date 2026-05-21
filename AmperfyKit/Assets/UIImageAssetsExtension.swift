//
//  UIImageAssetsExtension.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 06.06.22.
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
import SwiftUI

// MARK: - ArtworkIconSizeType

public enum ArtworkIconSizeType: CGFloat {
  // rawValue will be used as insets
  case small = 50.0
  case big = 20.0

  public static let defaultSize: CGFloat = 200.0
}

// MARK: - LightDarkModeType

public enum LightDarkModeType: CaseIterable {
  case light
  case dark

  public var description: String {
    switch self {
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }
}

// MARK: - ArtworkType

public enum ArtworkType: CaseIterable {
  case song
  case album
  case genre
  case artist
  case podcast
  case podcastEpisode
  case playlist
  case folder
  case radio

  public var description: String {
    switch self {
    case .song:
      return "Song"
    case .album:
      return "Album"
    case .genre:
      return "Genre"
    case .artist:
      return "Artist"
    case .podcast:
      return "Podcast"
    case .podcastEpisode:
      return "PodcastEpisode"
    case .playlist:
      return "Playlist"
    case .folder:
      return "Folder"
    case .radio:
      return "Radio"
    }
  }

  public var image: AmperfyImage {
    switch self {
    case .song: return .musicalNotes
    case .podcastEpisode: return .podcastEpisode
    case .album: return .album
    case .artist: return .artist
    case .genre: return .genre
    case .playlist: return .playlist
    case .podcast: return .podcast
    case .folder: return .folder
    case .radio: return .radio
    }
  }
}

// MARK: - AmperfyImage

public struct AmperfyImage: Sendable {
  public let systemName: String
  public let assetName: String

  private init(_ systemName: String = "", assetName: String = "") {
    self.systemName = systemName
    self.assetName = assetName
  }

  // MARK: use Image(: bundle: ) for the following images because these are in the asset catalog

  public static let albumNewest = Self(assetName: "album_newest")
  public static let albumRecent = Self(assetName: "album_recent")
  public static let contextQueueAppend = Self(assetName: "context_queue_append")
  public static let contextQueueInsert = Self(assetName: "context_queue_insert")
  public static let podcast = Self(assetName: "podcast")
  public static let podcastEpisode = Self(assetName: "podcast")
  public static let podcastQueueAppend = Self(assetName: "context_queue_append")
  public static let podcastQueueInsert = Self(assetName: "context_queue_insert")
  public static let userQueueAppend = Self(assetName: "user_queue_append")
  public static let userQueueInsert = Self(assetName: "user_queue_insert")

  // MARK: use Image(systemName: ) for the following images

  public static let account = Self("person.circle.fill")
  public static let airplayaudio = Self("airplayaudio")
  public static let album = Self("square.stack")
  public static let antenna = Self("antenna.radiowaves.left.and.right")
  public static let arrowRight = Self("arrow.right.circle.fill")
  public static let arrowTurnUp = Self("arrowshape.turn.up.backward.circle.fill")
  public static let artist = Self("music.mic")
  public static let audioVisualizer = Self("circle.dashed")
  public static let ban = Self("circle.slash")
  public static let backwardMenu = Self("backward")
  public static let backwardFill = Self("backward.fill")
  public static let bars = Self("line.3.horizontal")
  public static let bell = Self("bell.fill")
  public static let cancleDownloads = Self("xmark.icloud")
  public static let check = Self("checkmark")
  public static let circle = Self("circle")
  public static let clear = Self("clear")
  public static let clipboard = Self("doc.on.doc")
  public static let clock = Self("clock")
  public static let cloudX = Self("xmark.icloud")
  public static let currentSongMenu = Self("music.note")
  public static let display = Self("display")
  public static let doc = Self("doc.fill")
  public static let documents = Self("document.on.document")
  public static let download = Self("arrow.down.circle")
  public static let ellipsis = Self("ellipsis")
  public static let equalizer = Self("chart.bar.xaxis")
  public static let exclamation = Self("exclamationmark")
  public static let filter = Self("line.3.horizontal.decrease")
  public static let followLink = Self("arrowshape.turn.up.forward.fill")
  public static let folder = Self("folder.fill")
  public static let forwardFill = Self("forward.fill")
  public static let forwardMenu = Self("forward")
  public static let genre = Self("guitars.fill")
  public static let goBackward15 = Self("gobackward.15")
  public static let goForward30 = Self("goforward.30")
  public static let grid = Self("square.grid.2x2")
  public static let hammer = Self("hammer.circle.fill")
  public static let heartEmpty = Self("heart")
  public static let heartFill = Self("heart.fill")
  public static let heartSlash = Self("heart.slash")
  public static let home = Self("house.fill")
  public static let info = Self("info.circle")
  public static let isSelected = Self("checkmark.circle.fill")
  public static let leftRightPlay = Self("play.rectangle.on.rectangle")
  public static let listBullet = Self("list.bullet")
  public static let login = Self("arrow.right.to.line")
  public static let lyrics = Self("quote.bubble")
  public static let miniPlayer = Self("play.rectangle.on.rectangle")
  public static let minus = Self("minus")
  public static let musicLibrary = Self("music.note.square.stack.fill")
  public static let musicalNotes = Self("music.note")
  public static let offlineMode = Self("network.slash")
  public static let onlineMode = Self("network")
  public static let openPlayerWindow = Self("macwindow")
  public static let pause = Self("pause.fill")
  public static let pauseMenu = Self("pause")
  public static let password = Self("key.fill")
  public static let person = Self("person.circle")
  public static let photo = Self("photo.fill")
  public static let play = Self("play.fill")
  public static let playCircle = Self("play.circle.fill")
  public static let playMenu = Self("play")
  public static let playbackRate = Self("gauge.open.with.lines.needle.33percent")
  public static let playlist = Self("music.note.list")
  public static let playlistDisplayStyle = Self("list.bullet")
  public static let playlistPlus = Self("text.badge.plus")
  public static let playlistX = Self("text.badge.xmark")
  public static let plus = Self("plus")
  public static let plusCircle = Self("plus.circle")
  public static let radio = Self("dot.radiowaves.left.and.right")
  public static let redo = Self("gobackward")
  public static let refresh = Self("arrow.triangle.2.circlepath")
  public static let repeatAll = Self("repeat")
  public static let repeatMenu = Self("repeat")
  public static let repeatOff = Self("repeat.badge.xmark")
  public static let repeatOne = Self("repeat.1")
  public static let resize = Self("arrow.down.left.and.arrow.up.right")
  public static let search = Self("magnifyingglass")
  public static let server = Self("server.rack")
  public static let serverUrl = Self("globe")
  public static let settings = Self("gear")
  public static let shuffle = Self("shuffle")
  public static let shuffleMenu = Self("shuffle")
  public static let instantMix = Self("point.3.filled.connected.trianglepath.dotted")
  public static let skipBackward10 = Self("gobackward.10")
  public static let skipBackward15 = Self("gobackward.15")
  public static let skipBackwardMenu = Self("gobackward")
  public static let skipForward10 = Self("goforward.10")
  public static let skipForward30 = Self("goforward.30")
  public static let skipForwardMenu = Self("goforward")
  public static let sleep = Self("moon.zzz")
  public static let sleepFill = Self("moon.zzz.fill")
  public static let sort = Self("arrow.up.arrow.down")
  public static let sparkles = Self("sparkles")
  public static let squareArrow = Self("arrow.forward.square")
  public static let starEmpty = Self("star")
  public static let starFill = Self("star.fill")
  public static let starSlash = Self("star.slash")
  public static let startDownload = Self("arrow.down.circle")
  public static let stop = Self("stop.fill")
  public static let stopMenu = Self("stop")
  public static let switchPlayerWindow = Self("play.rectangle.on.rectangle")
  public static let trash = Self("trash")
  public static let triangleDown = Self("arrowtriangle.down.fill")
  public static let unSelected = Self("circle")
  public static let userCircleCheckmark = Self("person.crop.circle.fill.badge.checkmark")
  public static let userCirclePlus = Self("person.crop.circle.fill.badge.plus")
  public static let userPerson = Self("person.fill")
  public static let volumeMax = Self("speaker.wave.3.fill")
  public static let volumeMin = Self("speaker.fill")
  public static let xmark = Self("xmark")

  public var asImage: Image {
    if !assetName.isEmpty {
      return Image(assetName)
    } else {
      return Image(systemName: systemName)
    }
  }
}
