//
//  BackgroundTasksSection.swift
//  Amperfy
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

import AmperfyKit
import SwiftUI

// MARK: - BackgroundTasksSection

/// Read-only SwiftUI section for Settings → Library showing the current
/// status of each background task kind. No run/cancel controls — status only.
///
/// Refreshes on `BackgroundTaskStatusStore.didChangeNotification` using
/// NotificationCenter (matches the timer-based `.onReceive` pattern in
/// `LibrarySettingsView`). No explicit `import Combine` needed — SwiftUI's
/// built-in Combine integration handles `NotificationCenter.default.publisher(for:)`.
struct BackgroundTasksSection: View {
  @State
  private var currentStatuses: [TaskKind: TaskStatus] = [:]

  var body: some View {
    SettingsSection(content: {
      taskStatusRow(label: "Album Scan", kind: .albumScan)
      taskStatusRow(label: "Playlist Sync", kind: .playlistItemSync)
      taskStatusRow(label: "Track Adjacency", kind: .adjacencyCompute)
    }, header: "Background Tasks")
      .onAppear {
        loadCurrentStatuses()
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: BackgroundTaskStatusStore.didChangeNotification
        )
      ) { _ in
        loadCurrentStatuses()
      }
  }

  // MARK: - Row builder

  @ViewBuilder
  private func taskStatusRow(label: String, kind: TaskKind) -> some View {
    let effectiveStatus = effectiveStatusForDisplay(kind: kind)
    SettingsRow(title: label) {
      HStack(spacing: 6) {
        statusIcon(for: effectiveStatus)
        SecondaryText(statusDetailText(for: effectiveStatus))
      }
    }
  }

  /// If the runner kill-switch is off, override all rows to show disabled.
  private func effectiveStatusForDisplay(kind: TaskKind) -> TaskStatus {
    guard BackgroundRunnerFeatureFlags.shared.runnerEnabled else {
      return .disabled(reason: "Runner disabled")
    }
    return currentStatuses[kind] ?? .idle
  }

  // MARK: - Status icon

  @ViewBuilder
  private func statusIcon(for taskStatus: TaskStatus) -> some View {
    switch taskStatus {
    case .idle:
      Image(systemName: "clock.fill")
        .foregroundColor(.secondary)
    case .queued:
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundColor(.blue)
    case .running:
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundColor(.blue)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.red)
    case .disabled:
      Image(systemName: "minus.circle.fill")
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Detail text

  private func statusDetailText(for taskStatus: TaskStatus) -> String {
    switch taskStatus {
    case .idle:
      return "Not yet run"
    case .queued:
      return "Queued"
    case .running:
      return "Running..."
    case let .completed(completionDate, durationSeconds):
      let relativeTimeText = relativeTimeString(from: completionDate)
      let durationText = formattedDuration(durationSeconds)
      return "Completed \(relativeTimeText) (\(durationText))"
    case let .failed(_, errorMessage):
      return "Failed: \(errorMessage)"
    case .disabled:
      return "Disabled"
    }
  }

  // MARK: - Formatting helpers

  private func relativeTimeString(from date: Date) -> String {
    let relativeFormatter = RelativeDateTimeFormatter()
    relativeFormatter.unitsStyle = .abbreviated
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
  }

  /// "Xs" for under 60 seconds, "Xm Ys" for longer.
  private func formattedDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
      return "\(Int(seconds))s"
    } else {
      let totalSeconds = Int(seconds)
      let minutes = totalSeconds / 60
      let remainingSeconds = totalSeconds % 60
      return "\(minutes)m \(remainingSeconds)s"
    }
  }

  // MARK: - State refresh

  private func loadCurrentStatuses() {
    var freshStatuses: [TaskKind: TaskStatus] = [:]
    for kind in TaskKind.allCases {
      freshStatuses[kind] = BackgroundTaskStatusStore.shared.status(for: kind)
    }
    currentStatuses = freshStatuses
  }
}
