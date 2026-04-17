//
//  BackgroundTaskStatusStore.swift
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

import Combine
import Foundation

// MARK: - TaskStatus

/// The current lifecycle state for a single background task kind.
/// `.queued` and `.running` are transient (in-memory only).
/// `.completed`, `.failed`, `.disabled`, and `.idle` are persisted to UserDefaults.
public enum TaskStatus: Equatable, Sendable {
  case idle
  case queued(since: Date)
  case running(since: Date)
  case completed(at: Date, durationSeconds: TimeInterval)
  case failed(at: Date, errorMessage: String)
  case disabled(reason: String)
}

// MARK: - PersistedTaskStatus

/// Codable shape for terminal states written to UserDefaults.
/// Transient states (`.queued`, `.running`) are never written.
private struct PersistedTaskStatus: Codable {
  enum PersistedKind: String, Codable {
    case idle, completed, failed, disabled
  }

  let kind: PersistedKind
  let timestamp: Date?
  let durationSeconds: TimeInterval?
  let message: String?
}

// MARK: - BackgroundTaskStatusStore

/// UserDefaults-backed, Combine-published store for background task statuses.
/// Follows the `ThemeStore` / `StylingPresetStore` singleton pattern.
///
/// Key scheme: `"amperfy.fork.runner.status.<taskKind.rawValue>"`
public final class BackgroundTaskStatusStore: @unchecked Sendable {
  public static let shared = BackgroundTaskStatusStore()

  /// Posted on every status transition. SwiftUI views can subscribe via
  /// `.onReceive(NotificationCenter.default.publisher(for:))`.
  public static let didChangeNotification = Notification.Name(
    "amperfy.fork.runner.status.didChange"
  )

  private let defaults: UserDefaults
  private let accessQueue = DispatchQueue(
    label: "amperfy.fork.runner.statusStore",
    attributes: .concurrent
  )
  private var inMemoryStatuses: [TaskKind: TaskStatus] = [:]
  private let statusSubject: CurrentValueSubject<[TaskKind: TaskStatus], Never>

  // MARK: - Public interface

  /// Combine publisher. Emits the full status dictionary on every transition.
  public var statusPublisher: AnyPublisher<[TaskKind: TaskStatus], Never> {
    statusSubject.eraseToAnyPublisher()
  }

  /// Thread-safe read of a single kind's current status.
  public func status(for kind: TaskKind) -> TaskStatus {
    accessQueue.sync {
      inMemoryStatuses[kind] ?? .idle
    }
  }

  /// Transition `kind` to `newStatus`. Called by the runner — not directly
  /// by workers. Terminal states are persisted to UserDefaults immediately.
  public func transition(_ kind: TaskKind, to newStatus: TaskStatus) {
    accessQueue.async(flags: .barrier) {
      self.inMemoryStatuses[kind] = newStatus
      if let persistedStatus = Self.persistedShape(for: newStatus) {
        self.persist(persistedStatus, forKind: kind)
      }
      let snapshot = self.inMemoryStatuses
      DispatchQueue.main.async {
        self.statusSubject.send(snapshot)
        NotificationCenter.default.post(
          name: BackgroundTaskStatusStore.didChangeNotification,
          object: nil
        )
      }
    }
  }

  // MARK: - Init with UserDefaults DI (enables isolated test instances)

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Load all kinds from persisted state; anything absent defaults to .idle.
    var loadedStatuses: [TaskKind: TaskStatus] = [:]
    for kind in TaskKind.allCases {
      if let persistedStatus = Self.loadPersistedStatus(for: kind, from: defaults) {
        loadedStatuses[kind] = persistedStatus
      } else {
        loadedStatuses[kind] = .idle
      }
    }
    self.inMemoryStatuses = loadedStatuses
    self.statusSubject = CurrentValueSubject(loadedStatuses)
  }

  // MARK: - Persistence helpers

  private static func userDefaultsKey(for kind: TaskKind) -> String {
    "amperfy.fork.runner.status.\(kind.rawValue)"
  }

  private func persist(_ persistedStatus: PersistedTaskStatus, forKind kind: TaskKind) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let encodedData = try? encoder.encode(persistedStatus) {
      defaults.set(encodedData, forKey: Self.userDefaultsKey(for: kind))
    }
  }

  private static func loadPersistedStatus(
    for kind: TaskKind,
    from defaults: UserDefaults
  )
    -> TaskStatus? {
    guard let savedData = defaults.data(forKey: userDefaultsKey(for: kind)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let persistedStatus = try? decoder.decode(PersistedTaskStatus.self, from: savedData)
    else { return nil }
    return taskStatus(from: persistedStatus)
  }

  private static func taskStatus(from persistedStatus: PersistedTaskStatus) -> TaskStatus? {
    switch persistedStatus.kind {
    case .idle:
      return .idle
    case .completed:
      guard let timestamp = persistedStatus.timestamp,
            let durationSeconds = persistedStatus.durationSeconds
      else { return nil }
      return .completed(at: timestamp, durationSeconds: durationSeconds)
    case .failed:
      guard let timestamp = persistedStatus.timestamp,
            let errorMessage = persistedStatus.message
      else { return nil }
      return .failed(at: timestamp, errorMessage: errorMessage)
    case .disabled:
      let reason = persistedStatus.message ?? "Disabled"
      return .disabled(reason: reason)
    }
  }

  private static func persistedShape(for status: TaskStatus) -> PersistedTaskStatus? {
    switch status {
    case .idle:
      return PersistedTaskStatus(kind: .idle, timestamp: nil, durationSeconds: nil, message: nil)
    case let .completed(at, durationSeconds):
      return PersistedTaskStatus(
        kind: .completed,
        timestamp: at,
        durationSeconds: durationSeconds,
        message: nil
      )
    case let .failed(at, errorMessage):
      return PersistedTaskStatus(
        kind: .failed,
        timestamp: at,
        durationSeconds: nil,
        message: errorMessage
      )
    case let .disabled(reason):
      return PersistedTaskStatus(
        kind: .disabled,
        timestamp: nil,
        durationSeconds: nil,
        message: reason
      )
    case .queued, .running:
      // Transient states are NOT persisted.
      return nil
    }
  }
}
