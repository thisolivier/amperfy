//  AdjacencyProvider.swift
//  AmperfyKit

import Foundation

/// Placeholder protocol for Graph Explorer v2 adjacency queries.
/// No implementation yet — will be implemented when adjacency sidecar is integrated.
public protocol AdjacencyProvider {
  func adjacentSongs(to songId: String, limit: Int) -> [(song: Song, score: Double)]
}
