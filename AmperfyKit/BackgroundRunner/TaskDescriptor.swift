//
//  TaskDescriptor.swift
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

// MARK: - TaskDescriptor

/// Value type describing *what* to run: kind, why it was triggered, and at
/// what priority. No closures, no Core Data references — kept serialization-
/// friendly for a future remote executor path (see ARCH_PROPOSAL_PR19 §4).
public struct TaskDescriptor: Sendable {
  public let kind: TaskKind
  public let triggerReason: TriggerReason
  public let priority: TaskPriority

  // MARK: - TriggerReason

  public enum TriggerReason: String, Sendable {
    /// Kicked off automatically on app launch or a scheduled interval.
    case scheduled
    /// Kicked off by an explicit user action (e.g. a "run now" button in a future PR).
    case userRequested
    /// Triggered because upstream data changed and downstream state is stale.
    case invalidation
  }

  // MARK: - TaskPriority

  public enum TaskPriority: Int, Comparable, Sendable {
    case background = 0
    case userInitiated = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  // MARK: - Init

  public init(
    kind: TaskKind,
    triggerReason: TriggerReason = .scheduled,
    priority: TaskPriority = .background
  ) {
    self.kind = kind
    self.triggerReason = triggerReason
    self.priority = priority
  }
}
