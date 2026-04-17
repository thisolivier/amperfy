//
//  BackgroundTaskWorker.swift
//  AmperfyKit
//
//  Created by the Amperfy spike (PR 19a — Background task runner).
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

// MARK: - TaskProgress

/// Progress events emitted by a worker via `TaskRunContext.reportProgress`.
public enum TaskProgress: Sendable {
  case started
  case progress(done: Int, total: Int)
  case checkpoint(label: String)
}

// MARK: - TaskRunContext

/// What the runner provides to a worker when executing a task.
/// Workers must periodically check `isCancelled` and stop gracefully if true.
public final class TaskRunContext: @unchecked Sendable {
  /// Set to `true` by the runner when the operation is cancelled or the
  /// watchdog fires. Workers should check this periodically and return early.
  public let isCancelled: Atomic<Bool>

  /// Call this to emit progress events back to the runner (and on to the
  /// status store). All calls are safe from any thread.
  public let reportProgress: @Sendable (TaskProgress) -> ()

  public init(
    isCancelled: Atomic<Bool>,
    reportProgress: @escaping @Sendable (TaskProgress) -> ()
  ) {
    self.isCancelled = isCancelled
    self.reportProgress = reportProgress
  }
}

// MARK: - BackgroundTaskWorker

/// Protocol a concrete worker must implement to participate in the runner.
/// Workers are registered at app startup via `BackgroundTaskRunner.register(worker:)`.
///
/// No workers are registered in PR 19a — the skeleton compiles and runs
/// cleanly with zero registrations. Real workers arrive in PR 19b/c/d.
public protocol BackgroundTaskWorker: Sendable {
  /// The kind of task this worker handles. Must be unique per runner instance.
  var kind: TaskKind { get }

  /// Execute the task. Must check `context.isCancelled` periodically.
  /// Throw on unrecoverable error — the runner translates this to `.failed`.
  func run(descriptor: TaskDescriptor, context: TaskRunContext) async throws
}
