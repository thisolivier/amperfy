//
//  SharedContainerMigration.swift
//  AmperfyKit
//
//  Created for the AmperfyKit Architecture Separation epic.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import CoreData
import Foundation
import os.log

/// Migrates the SQLite store from the default app container to the shared App Group container.
/// Must be called BEFORE `CoreDataPersistentManager` initializes its persistent container.
public enum SharedContainerMigration {
  private static let log = OSLog(subsystem: "AmperfyKit", category: "SharedContainerMigration")

  /// The three file extensions that make up a SQLite persistent store.
  private static let storeFileExtensions = ["sqlite", "sqlite-wal", "sqlite-shm"]

  /// Runs the migration if the store exists at the old default location but NOT at the shared
  /// container location. This is safe to call on every launch — it no-ops if migration is
  /// unnecessary.
  ///
  /// - Parameter configuration: The `CoreDataConfiguration` describing the target shared container.
  /// - Returns: `true` if migration was performed, `false` if skipped.
  @discardableResult
  public static func migrateIfNeeded(configuration: CoreDataConfiguration) -> Bool {
    guard let sharedStoreURL = configuration.sharedStoreURL else {
      os_log("No shared container configured — skipping migration", log: log, type: .info)
      return false
    }

    let defaultStoreURL = defaultStoreLocation()

    // Only migrate if the old store exists and the new one does not
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: defaultStoreURL.path) else {
      os_log("No store at default location — skipping migration", log: log, type: .info)
      return false
    }

    if fileManager.fileExists(atPath: sharedStoreURL.path) {
      os_log(
        "Store already exists at shared container — skipping migration", log: log, type: .info
      )
      return false
    }

    os_log("Starting store migration to shared container", log: log, type: .info)

    // Ensure the shared container directory exists
    let sharedDirectory = sharedStoreURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
    } catch {
      os_log(
        "Failed to create shared container directory: %{public}@", log: log, type: .error,
        error.localizedDescription
      )
      return false
    }

    // Copy all store files to shared container (copy first, then remove originals)
    let baseName = defaultStoreURL.deletingPathExtension().lastPathComponent
    let sourceDirectory = defaultStoreURL.deletingLastPathComponent()
    let destinationDirectory = sharedStoreURL.deletingLastPathComponent()

    var copiedFiles: [URL] = []

    for fileExtension in storeFileExtensions {
      let sourceFile = sourceDirectory.appendingPathComponent("\(baseName).\(fileExtension)")
      let destinationFile = destinationDirectory.appendingPathComponent(
        "Amperfy.\(fileExtension)"
      )

      guard fileManager.fileExists(atPath: sourceFile.path) else {
        continue
      }

      do {
        try fileManager.copyItem(at: sourceFile, to: destinationFile)
        copiedFiles.append(destinationFile)
        os_log("Copied %{public}@ to shared container", log: log, type: .info, fileExtension)
      } catch {
        os_log(
          "Failed to copy %{public}@: %{public}@", log: log, type: .error, fileExtension,
          error.localizedDescription
        )
        // Roll back any files we already copied
        rollback(copiedFiles: copiedFiles, fileManager: fileManager)
        return false
      }
    }

    // Verify the main sqlite file was copied successfully
    guard fileManager.fileExists(atPath: sharedStoreURL.path) else {
      os_log("Verification failed — main sqlite file not at destination", log: log, type: .error)
      rollback(copiedFiles: copiedFiles, fileManager: fileManager)
      return false
    }

    // Remove originals now that we have a verified copy
    for fileExtension in storeFileExtensions {
      let sourceFile = sourceDirectory.appendingPathComponent("\(baseName).\(fileExtension)")
      if fileManager.fileExists(atPath: sourceFile.path) {
        do {
          try fileManager.removeItem(at: sourceFile)
        } catch {
          // Non-fatal: old files left behind as a backup
          os_log(
            "Could not remove old %{public}@ (non-fatal)", log: log, type: .info, fileExtension
          )
        }
      }
    }

    os_log("Store migration to shared container completed successfully", log: log, type: .info)
    return true
  }

  // MARK: - Private Helpers

  /// Returns the default Core Data store URL (same as NSPersistentContainer would use).
  private static func defaultStoreLocation() -> URL {
    let applicationSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return applicationSupportURL.appendingPathComponent("Amperfy.sqlite")
  }

  /// Removes any files that were copied during a failed migration attempt.
  private static func rollback(copiedFiles: [URL], fileManager: FileManager) {
    for fileURL in copiedFiles {
      try? fileManager.removeItem(at: fileURL)
    }
    os_log("Rolled back partially-copied files", log: log, type: .info)
  }
}
