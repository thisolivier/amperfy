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
  ///
  /// These budgets cover EXECUTION only — the watchdog is armed when a task
  /// actually starts, never while it waits its turn on the serial queue.
  private enum WatchdogTimeout {
    static let albumScan: TimeInterval = 15 * 60 // 15 minutes
    static let adjacencyCompute: TimeInterval = 5 * 60 // 5 minutes
    /// A full library pass is ~360 playlists at 1–2 s of network each, so the
    /// worst realistic run lands well inside 20 minutes.
    static let playlistItemSync: TimeInterval = 20 * 60 // 20 minutes

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
  private let watchdogTimeoutProvider: @Sendable (TaskKind) -> TimeInterval

  // Guards every piece of per-kind in-flight bookkeeping below.
  private let taskStateLock = NSLock()
  // Identifies the enqueue that currently owns a kind, so a late teardown from a
  // superseded run can never clear the bookkeeping of the run that replaced it.
  private var inFlightRunTokens: [TaskKind: UUID] = [:]
  // Active watchdog work items keyed by task kind.
  private var activeWatchdogItems: [TaskKind: DispatchWorkItem] = [:]
  // Active cancel flags keyed by task kind so the watchdog can set them.
  private var activeCancelFlags: [TaskKind: Atomic<Bool>] = [:]

  // MARK: - Init

  public init(
    featureFlags: BackgroundRunnerFeatureFlags = .shared,
    statusStore: BackgroundTaskStatusStore = .shared,
    watchdogTimeoutProvider: (@Sendable (TaskKind) -> TimeInterval)? = nil
  ) {
    self.featureFlags = featureFlags
    self.statusStore = statusStore
    self.watchdogTimeoutProvider = watchdogTimeoutProvider
      ?? { kind in WatchdogTimeout.timeout(for: kind) }
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

  /// `true` when a worker has been registered for `kind`. Callers that enqueue
  /// opportunistically (e.g. on app foreground) use this to avoid queueing a
  /// task before `MetaManager` has had a chance to register its workers.
  public func hasRegisteredWorker(for kind: TaskKind) -> Bool {
    workerRegistryLock.withLock {
      workerRegistry[kind] != nil
    }
  }

  /// `true` when a task of `kind` is already queued or running.
  public func isQueuedOrRunning(kind: TaskKind) -> Bool {
    taskStateLock.withLock {
      inFlightRunTokens[kind] != nil
    }
  }

  /// Enqueue a task. Returns `false` and is a no-op when the relevant
  /// phase flag is disabled, or when a task of the same kind is already
  /// queued or running.
  @discardableResult
  public func enqueue(_ descriptor: TaskDescriptor) -> Bool {
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

    // Idempotence: re-enqueueing a kind that is already in flight must not stack
    // a duplicate run. Callers re-enqueue freely (app foreground, "Show in
    // Playlists" taps) and rely on this being a cheap no-op.
    let runToken = UUID()
    let wasClaimed = taskStateLock.withLock { () -> Bool in
      guard inFlightRunTokens[descriptor.kind] == nil else { return false }
      inFlightRunTokens[descriptor.kind] = runToken
      return true
    }
    guard wasClaimed else { return false }

    let cancelFlag = Atomic<Bool>(wrappedValue: false)
    statusStore.transition(descriptor.kind, to: .queued(since: Date()))

    let operation = BackgroundTaskOperation(
      descriptor: descriptor,
      worker: workerForKind,
      cancelFlag: cancelFlag,
      statusStore: statusStore,
      onStart: { [weak self] in
        // Armed here, not at enqueue time: the budget must cover execution
        // only. Arming at enqueue burned the whole budget while the task
        // waited behind a multi-hour album scan on this serial queue, so it
        // timed out having never run a single line of work.
        self?.scheduleWatchdog(for: descriptor.kind, cancelFlag: cancelFlag)
      },
      onCompletion: { [weak self] in
        self?.clearWatchdog(for: descriptor.kind)
      }
    )
    // `completionBlock` fires on every terminal path, including an operation
    // cancelled before `main()` ever ran, so the kind can never stay claimed.
    operation.completionBlock = { [weak self] in
      self?.releaseInFlightClaim(for: descriptor.kind, runToken: runToken)
    }
    applyPriority(descriptor.priority, to: operation)
    taskQueue.addOperation(operation)
    return true
  }

  /// Maps the descriptor's priority onto the operation so a user-initiated task
  /// jumps ahead of the scheduled background work already sitting on the queue.
  private func applyPriority(
    _ priority: TaskDescriptor.TaskPriority,
    to operation: Operation
  ) {
    switch priority {
    case .userInitiated:
      operation.queuePriority = .veryHigh
      operation.qualityOfService = .userInitiated
    case .background:
      operation.queuePriority = .normal
    }
  }

  /// Cancel all running and queued tasks. Sets any active task to `.failed`.
  public func cancelAll() {
    taskQueue.cancelAllOperations()
    taskStateLock.withLock {
      for (_, watchdogItem) in activeWatchdogItems {
        watchdogItem.cancel()
      }
      activeWatchdogItems.removeAll()
      activeCancelFlags.removeAll()
      inFlightRunTokens.removeAll()
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
    let timeoutInterval = watchdogTimeoutProvider(kind)
    let watchdogWorkItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      cancelFlag.wrappedValue = true
      statusStore.transition(
        kind,
        to: .failed(at: Date(), errorMessage: "timeout")
      )
      clearWatchdog(for: kind)
    }
    taskStateLock.withLock {
      // Cancel any existing watchdog for this kind before replacing it. With the
      // idempotence guard in `enqueue` only one run of a kind is ever in flight,
      // so this can no longer orphan a live task's cancel flag.
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
    taskStateLock.withLock {
      activeWatchdogItems[kind]?.cancel()
      activeWatchdogItems.removeValue(forKey: kind)
      activeCancelFlags.removeValue(forKey: kind)
    }
  }

  /// Frees `kind` for a fresh enqueue — but only if the claim still belongs to
  /// the run that is tearing down. A `cancelAll` followed by an immediate
  /// re-enqueue hands the kind to a new run, whose claim must survive the old
  /// run's late completion.
  private func releaseInFlightClaim(for kind: TaskKind, runToken: UUID) {
    taskStateLock.withLock {
      guard inFlightRunTokens[kind] == runToken else { return }
      inFlightRunTokens.removeValue(forKey: kind)
    }
  }
}

// MARK: - Test support

extension BackgroundTaskRunner {
  /// Snapshot of everything currently on the queue. Test support only — nothing
  /// in the app reads the queue directly.
  var queuedTasksSnapshot: [(kind: TaskKind, queuePriority: Operation.QueuePriority)] {
    taskQueue.operations.compactMap { operation in
      guard let backgroundTaskOperation = operation as? BackgroundTaskOperation
      else { return nil }
      return (
        kind: backgroundTaskOperation.taskKind,
        queuePriority: backgroundTaskOperation.queuePriority
      )
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
  private let onStart: () -> ()
  private let onCompletion: () -> ()

  var taskKind: TaskKind { descriptor.kind }

  init(
    descriptor: TaskDescriptor,
    worker: (any BackgroundTaskWorker)?,
    cancelFlag: Atomic<Bool>,
    statusStore: BackgroundTaskStatusStore,
    onStart: @escaping () -> (),
    onCompletion: @escaping () -> ()
  ) {
    self.descriptor = descriptor
    self.worker = worker
    self.cancelFlag = cancelFlag
    self.statusStore = statusStore
    self.onStart = onStart
    self.onCompletion = onCompletion
  }

  override func main() {
    let taskStartTime = Date()
    let taskKind = descriptor.kind

    statusStore.transition(taskKind, to: .running(since: taskStartTime))
    onStart()

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
