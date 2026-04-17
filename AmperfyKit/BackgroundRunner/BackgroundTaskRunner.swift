//
//  BackgroundTaskRunner.swift
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

// MARK: - BackgroundTaskRunner

/// Serial OperationQueue-backed runner. Singleton.
///
/// PR 19a skeleton: compiles and runs safely with zero registered workers.
/// Real workers are added in PR 19b/c/d. The runner is standalone — it is NOT
/// wired into MetaManager or AmperKit yet (see ARCH_PROPOSAL_PR19 §9).
public final class BackgroundTaskRunner: @unchecked Sendable {
  public static let shared = BackgroundTaskRunner()

  // MARK: - Internal configuration

  /// Watchdog timeout ceilings per task kind (in seconds).
  private enum WatchdogTimeout {
    static let albumScan: TimeInterval = 15 * 60 // 15 minutes
    static let adjacencyCompute: TimeInterval = 5 * 60 // 5 minutes
    static let playlistItemSync: TimeInterval = 10 * 60 // 10 minutes

    static func timeout(for kind: TaskKind) -> TimeInterval {
      switch kind {
      case .albumScan: return albumScan
      case .adjacencyCompute: return adjacencyCompute
      case .playlistItemSync: return playlistItemSync
      }
    }
  }

  private let taskQueue: OperationQueue
  private let workerRegistryLock = NSLock()
  private var workerRegistry: [TaskKind: any BackgroundTaskWorker] = [:]
  private let featureFlags: BackgroundRunnerFeatureFlags
  private let statusStore: BackgroundTaskStatusStore

  // Active watchdog work items keyed by task kind.
  private let watchdogLock = NSLock()
  private var activeWatchdogItems: [TaskKind: DispatchWorkItem] = [:]
  // Active cancel flags keyed by task kind so the watchdog can set them.
  private var activeCancelFlags: [TaskKind: Atomic<Bool>] = [:]

  // MARK: - Init

  public init(
    featureFlags: BackgroundRunnerFeatureFlags = .shared,
    statusStore: BackgroundTaskStatusStore = .shared
  ) {
    self.featureFlags = featureFlags
    self.statusStore = statusStore
    self.taskQueue = OperationQueue()
    taskQueue.maxConcurrentOperationCount = 1
    taskQueue.name = "amperfy.fork.backgroundTaskRunner"
  }

  // MARK: - Public API

  /// Register a worker for a given task kind. Call at app startup, before any `enqueue`.
  public func register(worker: any BackgroundTaskWorker) {
    workerRegistryLock.withLock {
      workerRegistry[worker.kind] = worker
    }
  }

  /// Enqueue a task. Returns `false` and is a no-op when the runner or the
  /// relevant phase flag is disabled.
  @discardableResult
  public func enqueue(_ descriptor: TaskDescriptor) -> Bool {
    guard featureFlags.runnerEnabled else {
      return false
    }

    if descriptor.kind == .playlistItemSync, !featureFlags.phase2Enabled {
      statusStore.transition(
        .playlistItemSync,
        to: .disabled(reason: "Phase 2 disabled")
      )
      return false
    }

    let workerForKind: (any BackgroundTaskWorker)? = workerRegistryLock.withLock {
      workerRegistry[descriptor.kind]
    }

    let cancelFlag = Atomic<Bool>(wrappedValue: false)
    scheduleWatchdog(for: descriptor.kind, cancelFlag: cancelFlag)
    statusStore.transition(descriptor.kind, to: .queued(since: Date()))

    let operation = BackgroundTaskOperation(
      descriptor: descriptor,
      worker: workerForKind,
      cancelFlag: cancelFlag,
      statusStore: statusStore,
      onCompletion: { [weak self] in
        self?.clearWatchdog(for: descriptor.kind)
      }
    )
    taskQueue.addOperation(operation)
    return true
  }

  /// Cancel all running and queued tasks. Sets any active task to `.failed`.
  public func cancelAll() {
    taskQueue.cancelAllOperations()
    watchdogLock.withLock {
      for (_, watchdogItem) in activeWatchdogItems {
        watchdogItem.cancel()
      }
      activeWatchdogItems.removeAll()
      activeCancelFlags.removeAll()
    }
    for kind in TaskKind.allCases {
      let currentStatus = statusStore.status(for: kind)
      switch currentStatus {
      case .queued, .running:
        statusStore.transition(
          kind,
          to: .failed(at: Date(), errorMessage: "Cancelled")
        )
      default:
        break
      }
    }
  }

  /// Call on every app launch. Transitions any `.running` status entries
  /// left over from a prior session to `.failed("interrupted — app was terminated")`.
  /// This handles crash or force-quit scenarios where the watchdog never fired.
  public func performLaunchSweep() {
    for kind in TaskKind.allCases {
      let currentStatus = statusStore.status(for: kind)
      if case .running = currentStatus {
        statusStore.transition(
          kind,
          to: .failed(at: Date(), errorMessage: "interrupted — app was terminated")
        )
      }
    }
  }

  // MARK: - Watchdog management

  private func scheduleWatchdog(for kind: TaskKind, cancelFlag: Atomic<Bool>) {
    let timeoutInterval = WatchdogTimeout.timeout(for: kind)
    let watchdogWorkItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      cancelFlag.wrappedValue = true
      statusStore.transition(
        kind,
        to: .failed(at: Date(), errorMessage: "timeout")
      )
      clearWatchdog(for: kind)
    }
    watchdogLock.withLock {
      // Cancel any existing watchdog for this kind before replacing it.
      activeWatchdogItems[kind]?.cancel()
      activeWatchdogItems[kind] = watchdogWorkItem
      activeCancelFlags[kind] = cancelFlag
    }
    DispatchQueue.global(qos: .background).asyncAfter(
      deadline: .now() + timeoutInterval,
      execute: watchdogWorkItem
    )
  }

  private func clearWatchdog(for kind: TaskKind) {
    watchdogLock.withLock {
      activeWatchdogItems[kind]?.cancel()
      activeWatchdogItems.removeValue(forKey: kind)
      activeCancelFlags.removeValue(forKey: kind)
    }
  }
}

// MARK: - BackgroundTaskOperation

/// An `AsyncOperation` subclass that wraps a single worker execution.
/// Handles the full status lifecycle: running → completed/failed.
private final class BackgroundTaskOperation: AsyncOperation {
  private let descriptor: TaskDescriptor
  private let worker: (any BackgroundTaskWorker)?
  private let cancelFlag: Atomic<Bool>
  private let statusStore: BackgroundTaskStatusStore
  private let onCompletion: () -> ()

  init(
    descriptor: TaskDescriptor,
    worker: (any BackgroundTaskWorker)?,
    cancelFlag: Atomic<Bool>,
    statusStore: BackgroundTaskStatusStore,
    onCompletion: @escaping () -> ()
  ) {
    self.descriptor = descriptor
    self.worker = worker
    self.cancelFlag = cancelFlag
    self.statusStore = statusStore
    self.onCompletion = onCompletion
  }

  override func main() {
    let taskStartTime = Date()
    let taskKind = descriptor.kind

    statusStore.transition(taskKind, to: .running(since: taskStartTime))

    Task {
      defer {
        onCompletion()
        finish()
      }
      guard let concreteWorker = worker else {
        statusStore.transition(
          taskKind,
          to: .failed(
            at: Date(),
            errorMessage: "no worker registered for \(taskKind.rawValue)"
          )
        )
        return
      }

      guard !isCancelled, !cancelFlag.wrappedValue else {
        statusStore.transition(
          taskKind,
          to: .failed(at: Date(), errorMessage: "cancelled before start")
        )
        return
      }

      let taskRunContext = TaskRunContext(
        isCancelled: cancelFlag,
        reportProgress: { _ in /* PR 19b will wire this to fine-grained progress */ }
      )

      do {
        try await concreteWorker.run(descriptor: descriptor, context: taskRunContext)
        let elapsedSeconds = Date().timeIntervalSince(taskStartTime)
        statusStore.transition(
          taskKind,
          to: .completed(at: Date(), durationSeconds: elapsedSeconds)
        )
      } catch {
        statusStore.transition(
          taskKind,
          to: .failed(at: Date(), errorMessage: error.localizedDescription)
        )
      }
    }
  }
}
