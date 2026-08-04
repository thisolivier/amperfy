//
//  PlaylistFolderTreeExporter.swift
//  AmperfyKit
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
//  Copyright (c) 2026 Olivier Butler. All rights reserved.
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
import os.log

// MARK: - PlaylistFolderExportFolder

/// A folder as written to the export file.
public struct PlaylistFolderExportFolder: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  /// Empty string for a root-level folder, matching the server's spelling.
  public let parentId: String
  public let sortOrder: Int?

  public init(id: String, name: String, parentId: String, sortOrder: Int?) {
    self.id = id
    self.name = name
    self.parentId = parentId
    self.sortOrder = sortOrder
  }
}

// MARK: - PlaylistFolderExportPlacement

/// A placement as written to the export file.
///
/// `playlistName` comes first deliberately: server ids churn across reinstalls,
/// resyncs and library rebuilds, but the name a user gave a playlist survives
/// all of them. The id is recorded as a secondary hint only.
public struct PlaylistFolderExportPlacement: Codable, Sendable, Equatable {
  public let playlistName: String
  public let playlistId: String
  /// Empty string for a placement at the root.
  public let folderId: String
  public let sortOrder: Int?

  public init(playlistName: String, playlistId: String, folderId: String, sortOrder: Int?) {
    self.playlistName = playlistName
    self.playlistId = playlistId
    self.folderId = folderId
    self.sortOrder = sortOrder
  }
}

// MARK: - PlaylistFolderTreeExport

/// The whole folder organization, in the shape written to disk.
public struct PlaylistFolderTreeExport: Codable, Sendable, Equatable {
  /// Bumped only when the file shape changes incompatibly.
  public static let currentFormatVersion = 1

  public let exportFormatVersion: Int
  public let exportedAt: Date
  public let folders: [PlaylistFolderExportFolder]
  public let placements: [PlaylistFolderExportPlacement]

  public init(
    exportFormatVersion: Int = PlaylistFolderTreeExport.currentFormatVersion,
    exportedAt: Date,
    folders: [PlaylistFolderExportFolder],
    placements: [PlaylistFolderExportPlacement]
  ) {
    self.exportFormatVersion = exportFormatVersion
    self.exportedAt = exportedAt
    self.folders = folders
    self.placements = placements
  }
}

// MARK: - PlaylistFolderTreeExporter

/// Writes the folder organization to a user-reachable JSON file after every
/// successful local mutation.
///
/// This is a safety net, not a sync mechanism. The 2026-08-02 loss was
/// unrecoverable because the folder tree existed only inside an app-private
/// SQLite store and on a server that had just lost it. A plain JSON file the
/// owner can open in the Files app means a resync, a reinstall, or another round
/// of server-id churn is an inconvenience rather than a rebuild-from-memory.
///
/// The app has no iCloud entitlement, so the file goes to the app's Documents
/// directory, which `UIFileSharingEnabled` exposes to the Files app.
///
/// Two generations are kept: the current file and one `.previous` copy, so a
/// mutation made against already-damaged state does not destroy the last good
/// snapshot in the same breath.
/// Not `final`: the batching guarantee — one export per user action, however
/// many items that action touches — is only observable by counting writes, so
/// tests substitute a counting subclass.
public class PlaylistFolderTreeExporter: @unchecked Sendable {
  public static let exportDirectoryName = "PlaylistFolders"
  public static let currentFileName = "playlist-folders.json"
  public static let previousFileName = "playlist-folders.previous.json"

  private let exportDirectoryURL: URL
  private let fileManager: FileManager
  private let logger = Logger(
    subsystem: "dev.thisolivier.amperfy",
    category: "PlaylistFolderExport"
  )

  /// - Parameter exportDirectoryURL: directory to write into. Defaults to
  ///   `Documents/PlaylistFolders`; tests inject a temporary directory.
  public init(
    exportDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.exportDirectoryURL = exportDirectoryURL
      ?? Self.defaultExportDirectoryURL(fileManager: fileManager)
  }

  /// `Documents/PlaylistFolders` — visible in the Files app under the app's
  /// folder.
  public static func defaultExportDirectoryURL(fileManager: FileManager = .default) -> URL {
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return documentsURL.appendingPathComponent(exportDirectoryName, isDirectory: true)
  }

  public var currentFileURL: URL {
    exportDirectoryURL.appendingPathComponent(Self.currentFileName)
  }

  public var previousFileURL: URL {
    exportDirectoryURL.appendingPathComponent(Self.previousFileName)
  }

  // MARK: - Writing

  /// Roll the current file to `.previous` and write `export` in its place.
  @discardableResult
  public func write(_ export: PlaylistFolderTreeExport) throws -> URL {
    try fileManager.createDirectory(
      at: exportDirectoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encodedExport = try encoder.encode(export)

    // Roll before writing, so a crash mid-write cannot leave zero good copies.
    if fileManager.fileExists(atPath: currentFileURL.path) {
      if fileManager.fileExists(atPath: previousFileURL.path) {
        try fileManager.removeItem(at: previousFileURL)
      }
      try fileManager.copyItem(at: currentFileURL, to: previousFileURL)
    }

    try encodedExport.write(to: currentFileURL, options: .atomic)
    return currentFileURL
  }

  /// Write, logging rather than throwing. Mutation paths use this: failing to
  /// write the safety net must never fail the mutation itself.
  public func writeIgnoringFailure(_ export: PlaylistFolderTreeExport) {
    do {
      try write(export)
    } catch {
      logger.warning(
        """
        Playlist folder export failed: \(error.localizedDescription, privacy: .public). \
        Local folder state is unaffected.
        """
      )
    }
  }

  // MARK: - Reading

  /// Read back the current export, for round-trip verification and for any
  /// future restore flow.
  public func readCurrent() throws -> PlaylistFolderTreeExport {
    let encodedExport = try Data(contentsOf: currentFileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PlaylistFolderTreeExport.self, from: encodedExport)
  }

  /// Read back the rolled-over previous export, if one exists.
  public func readPrevious() throws -> PlaylistFolderTreeExport {
    let encodedExport = try Data(contentsOf: previousFileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PlaylistFolderTreeExport.self, from: encodedExport)
  }
}
