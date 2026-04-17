//
//  TaskKind.swift
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

// MARK: - TaskKind

/// Stable identity for each background task the runner manages.
/// `String` raw value keeps UserDefaults keys human-readable.
/// `CaseIterable` lets the status panel iterate all kinds without hardcoding.
public enum TaskKind: String, CaseIterable, Codable, Sendable {
  /// Phase 1: sync songs for albums that have no synced songs yet.
  case albumScan

  /// Phase 2: sync playlist items from the server (currently disabled).
  case playlistItemSync

  /// Phase 3: compute track adjacency scores from playlist co-occurrence data.
  case adjacencyCompute
}
