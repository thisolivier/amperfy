//
//  DefaultTrackAdjacencyService.swift
//  AmperfyKit
//
//  Orchestrates the track adjacency computation, storage, and query layers.
//  Replaces TrackAdjacencyStore.shared as the single entry point.
//
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

import CoreData
import Foundation

public final class DefaultTrackAdjacencyService: TrackAdjacencyService, @unchecked Sendable {
  private let computer: LocalTrackAdjacencyComputer
  private let store: TrackAdjacencySQLiteStore
  private let contextProvider: () -> NSManagedObjectContext
  private var staleFlag: Bool = true

  /// Shared singleton for app-wide use.
  nonisolated(unsafe) public static var shared: DefaultTrackAdjacencyService = {
    let documentsDirectory = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask).first!
    return DefaultTrackAdjacencyService(
      storageDirectory: documentsDirectory,
      contextProvider: {
        fatalError("contextProvider must be set via configure() before use")
      }
    )
  }()

  /// Called once at app launch to wire up the Core Data context factory.
  public static func configure(contextProvider: @escaping () -> NSManagedObjectContext) {
    shared = DefaultTrackAdjacencyService(
      storageDirectory: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first!,
      contextProvider: contextProvider
    )
  }

  public init(
    storageDirectory: URL,
    contextProvider: @escaping () -> NSManagedObjectContext,
    computer: LocalTrackAdjacencyComputer? = nil
  ) {
    self.store = TrackAdjacencySQLiteStore(directory: storageDirectory)
    self.computer = computer ?? LocalTrackAdjacencyComputer()
    self.contextProvider = contextProvider
    // If we already have data on disk, we're not stale
    if store.hasAnyData() {
      self.staleFlag = false
    }
  }

  // MARK: - TrackAdjacencyService

  public var isStale: Bool { staleFlag }

  public func computeIfNeeded() {
    guard staleFlag else { return }
    if store.hasAnyData() {
      staleFlag = false
      return
    }
    computeFromScratch()
  }

  public func invalidate() {
    staleFlag = true
  }

  /// Forces a full recomputation regardless of staleness.
  /// Runs synchronously on the calling thread, using performAndWait
  /// for Core Data access. Call from a background GCD queue.
  public func computeFromScratch() {
    MemoryReporter.logMemory(label: "adjacency-compute-start")
    let context = contextProvider()
    let provider = CoreDataPlaylistProvider(context: context)
    let capturedComputer = computer
    let capturedStore = store
    context.performAndWait {
      try? capturedComputer.compute(provider: provider, sink: capturedStore)
    }
    staleFlag = false
    MemoryReporter.logMemory(label: "adjacency-compute-done")
  }

  // MARK: - TrackAdjacencyQuerying (delegated to store)

  public func topRelated(
    for songId: String,
    limit: Int
  )
    -> [(songId: String, score: ScoredRelation)] {
    store.topRelated(for: songId, limit: limit)
  }

  public func hasData(for songId: String) -> Bool {
    store.hasData(for: songId)
  }

  public func score(for songIdA: String, _ songIdB: String) -> ScoredRelation? {
    store.score(for: songIdA, songIdB)
  }

  public func playlistCoOccurrenceCount(songIdA: String, songIdB: String) -> Int {
    store.playlistCoOccurrenceCount(songIdA: songIdA, songIdB: songIdB)
  }
}
