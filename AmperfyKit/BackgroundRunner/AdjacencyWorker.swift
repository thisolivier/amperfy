//
//  AdjacencyWorker.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 19 — Background task runner).
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

// MARK: - AdjacencyWorker

/// Phase 3 worker: compute track adjacency scores from playlist co-occurrence data.
///
/// Wraps `DefaultTrackAdjacencyService`. When the descriptor's `triggerReason`
/// is `.invalidation`, a full recomputation is forced. Otherwise,
/// `computeIfNeeded()` is called (skips if data already exists and is not stale).
public final class AdjacencyWorker: BackgroundTaskWorker, @unchecked Sendable {
  public var kind: TaskKind { .adjacencyCompute }

  private let log = OSLog(subsystem: "Amperfy", category: "AdjacencyWorker")

  public init() {}

  public func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws {
    os_log("AdjacencyWorker: starting adjacency compute", log: log, type: .info)
    MemoryReporter.logMemory(label: "adjacency-worker-start")
    context.reportProgress(.started)

    // Run synchronously on a background GCD queue — adjacency compute
    // uses performAndWait internally and must not run on the main thread.
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        if descriptor.triggerReason == .invalidation {
          // Force a full recompute: invalidate stale flag then recompute from scratch.
          DefaultTrackAdjacencyService.shared.invalidate()
          DefaultTrackAdjacencyService.shared.computeFromScratch()
        } else {
          // Respect staleness: skip if we already have up-to-date data.
          DefaultTrackAdjacencyService.shared.computeIfNeeded()
        }
        continuation.resume()
      }
    }

    MemoryReporter.logMemory(label: "adjacency-worker-done")
    os_log("AdjacencyWorker: adjacency compute complete", log: log, type: .info)
  }
}
