//
//  PendingPlaylistSongAddMigrationTest.swift
//  AmperfyKitTests
//
//  Created by Olivier Butler on 23.10.26.
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

@testable import AmperfyKit
import CoreData
import XCTest

/// Proves the v49 → v50 step actually runs.
///
/// `CoreDataMigrator.migrateStore` calls `fatalError` when a step fails, and
/// `CoreDataMigrationStep.init` calls `fatalError` when no mapping model can be
/// found or inferred — so a v50 model Core Data cannot infer a mapping for
/// would crash on launch for every existing install. The change is additive (a
/// new entity plus optional to-many inverses on Account, AbstractPlayable and
/// Playlist), which is inferrable, but "should be inferrable" is not evidence.
final class PendingPlaylistSongAddMigrationTest: XCTestCase {
  private var temporaryDirectoryURL: URL!
  private var storeURL: URL!

  override func setUpWithError() throws {
    temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pending-adds-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectoryURL,
      withIntermediateDirectories: true
    )
    storeURL = temporaryDirectoryURL.appendingPathComponent("Amperfy.sqlite")
  }

  override func tearDownWithError() throws {
    if let temporaryDirectoryURL,
       FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
      try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
  }

  private func createCoordinator(forModelResource resource: String) throws
    -> NSPersistentStoreCoordinator {
    let model = NSManagedObjectModel.managedObjectModel(forResource: resource)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType,
      configurationName: nil,
      at: storeURL,
      options: nil
    )
    return coordinator
  }

  private func createContext(for coordinator: NSPersistentStoreCoordinator)
    -> NSManagedObjectContext {
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
  }

  /// A store written by the previous release (model v49) migrates to v50, keeps
  /// its data, and comes out able to hold pending adds.
  func testV49StoreMigratesToV50AndKeepsItsData() throws {
    // Write a v49 store, the way an installed previous release would have.
    let legacyCoordinator = try createCoordinator(
      forModelResource: CoreDataMigrationVersion.v49.rawValue
    )
    let legacyContext = createContext(for: legacyCoordinator)
    let legacyPlaylist = NSEntityDescription.insertNewObject(
      forEntityName: "Playlist",
      into: legacyContext
    )
    legacyPlaylist.setValue("pl-legacy", forKey: "id")
    legacyPlaylist.setValue("Survivor", forKey: "name")
    try legacyContext.save()
    for store in legacyCoordinator.persistentStores {
      try legacyCoordinator.remove(store)
    }

    let migrator = CoreDataMigrator()
    XCTAssertTrue(
      migrator.requiresMigration(at: storeURL, toVersion: .current),
      "a v49 store must be recognised as needing the v50 step"
    )
    migrator.migrateStore(at: storeURL, toVersion: .current)
    XCTAssertFalse(
      migrator.requiresMigration(at: storeURL, toVersion: .current),
      "after migrating, the store is at the current version"
    )

    let migratedCoordinator = try createCoordinator(
      forModelResource: CoreDataMigrationVersion.current.rawValue
    )
    let migratedContext = createContext(for: migratedCoordinator)

    let playlistRequest = NSFetchRequest<NSManagedObject>(entityName: "Playlist")
    let migratedPlaylists = try migratedContext.fetch(playlistRequest)
    XCTAssertEqual(migratedPlaylists.count, 1, "the pre-existing playlist survived")
    XCTAssertEqual(migratedPlaylists.first?.value(forKey: "name") as? String, "Survivor")

    // The new entity exists and is empty: an upgrading device owes nothing on
    // day one, it only starts queueing from its first add.
    let pendingRequest = NSFetchRequest<NSManagedObject>(entityName: "PendingPlaylistSongAdd")
    XCTAssertEqual(try migratedContext.count(for: pendingRequest), 0)

    // And it is writable, wired to the playlist that came through the migration.
    let pendingAdd = NSEntityDescription.insertNewObject(
      forEntityName: "PendingPlaylistSongAdd",
      into: migratedContext
    )
    pendingAdd.setValue(Date(), forKey: "createdAt")
    pendingAdd.setValue(migratedPlaylists.first, forKey: "playlist")
    try migratedContext.save()
    XCTAssertEqual(try migratedContext.count(for: pendingRequest), 1)

    for store in migratedCoordinator.persistentStores {
      try migratedCoordinator.remove(store)
    }
  }

  /// The version chain has to reach v50, or `nextVersion()` stops early and the
  /// migrator silently leaves the store on an older model.
  func testVersionChainReachesV50() throws {
    XCTAssertEqual(CoreDataMigrationVersion.current, .v50)
    XCTAssertEqual(CoreDataMigrationVersion.v49.nextVersion(), .v50)
    XCTAssertNil(CoreDataMigrationVersion.v50.nextVersion(), "v50 is the end of the chain")
  }
}
