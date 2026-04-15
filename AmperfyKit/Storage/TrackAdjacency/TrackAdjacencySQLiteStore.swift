//
//  TrackAdjacencySQLiteStore.swift
//  AmperfyKit
//
//  SQLite-backed persistence for track adjacency scores.
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

import Foundation
import SQLite3

public final class TrackAdjacencySQLiteStore: ScoredRelationSink, TrackAdjacencyQuerying,
  @unchecked Sendable {
  private var databasePointer: OpaquePointer?
  private let databasePath: String

  // MARK: - Lifecycle

  public init(directory: URL) {
    let filePath = directory.appendingPathComponent("track_adjacency.sqlite").path
    self.databasePath = filePath

    let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    if sqlite3_open_v2(filePath, &databasePointer, openFlags, nil) != SQLITE_OK {
      NSLog("TrackAdjacencySQLiteStore: failed to open database at %@", filePath)
    }

    createTablesAndIndexes()

    // Clean up legacy JSON file if present
    let legacyJsonPath = directory.appendingPathComponent("track_adjacency.json").path
    if FileManager.default.fileExists(atPath: legacyJsonPath) {
      try? FileManager.default.removeItem(atPath: legacyJsonPath)
    }
  }

  deinit {
    if let databasePointer = databasePointer {
      sqlite3_close(databasePointer)
    }
  }

  // MARK: - ScoredRelationSink

  public func beginComputation() throws {
    execute("BEGIN TRANSACTION")
    execute("DELETE FROM scored_pairs")
    execute("COMMIT")
  }

  public func receiveBatch(_ relations: [ScoredRelation]) throws {
    let upsertSQL = """
    INSERT INTO scored_pairs (song_id1, song_id2, adjacency, co_membership, album, total)
    VALUES (?1, ?2, ?3, ?4, 0, ?3 + ?4)
    ON CONFLICT(song_id1, song_id2) DO UPDATE SET
        adjacency = adjacency + excluded.adjacency,
        co_membership = co_membership + excluded.co_membership,
        total = adjacency + excluded.adjacency + co_membership + excluded.co_membership + album
    """
    guard let statement = prepareStatement(upsertSQL) else { return }
    defer { sqlite3_finalize(statement) }

    execute("BEGIN TRANSACTION")
    for relation in relations {
      sqlite3_reset(statement)
      sqlite3_bind_text(statement, 1, (relation.songId1 as NSString).utf8String, -1, nil)
      sqlite3_bind_text(statement, 2, (relation.songId2 as NSString).utf8String, -1, nil)
      sqlite3_bind_double(statement, 3, Double(relation.adjacency))
      sqlite3_bind_double(statement, 4, Double(relation.coMembership))

      if sqlite3_step(statement) != SQLITE_DONE {
        NSLog(
          "TrackAdjacencySQLiteStore: upsert failed — %s",
          String(cString: sqlite3_errmsg(databasePointer))
        )
      }
    }
    execute("COMMIT")
  }

  public func applyAlbumBonus(_ bonus: Float, toSongIds songIds: [String]) throws {
    guard songIds.count >= 2 else { return }

    let updateSQL = """
    UPDATE scored_pairs SET album = ?1, total = adjacency + co_membership + ?1
    WHERE song_id1 = ?2 AND song_id2 = ?3
    """
    guard let statement = prepareStatement(updateSQL) else { return }
    defer { sqlite3_finalize(statement) }

    execute("BEGIN TRANSACTION")
    for indexA in 0 ..< songIds.count {
      for indexB in (indexA + 1) ..< songIds.count {
        let smallerId = min(songIds[indexA], songIds[indexB])
        let largerId = max(songIds[indexA], songIds[indexB])

        sqlite3_reset(statement)
        sqlite3_bind_double(statement, 1, Double(bonus))
        sqlite3_bind_text(statement, 2, (smallerId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (largerId as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
      }
    }
    execute("COMMIT")
  }

  public func finalizeComputation() throws {
    let dateFormatter = ISO8601DateFormatter()
    let dateString = dateFormatter.string(from: Date())

    let metadataSQL = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('last_computed', ?1)"
    guard let statement = prepareStatement(metadataSQL) else { return }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (dateString as NSString).utf8String, -1, nil)
    if sqlite3_step(statement) != SQLITE_DONE {
      NSLog(
        "TrackAdjacencySQLiteStore: metadata insert failed — %s",
        String(cString: sqlite3_errmsg(databasePointer))
      )
    }

    execute("PRAGMA optimize")
  }

  // MARK: - TrackAdjacencyQuerying

  public func topRelated(for songId: String, limit: Int) -> [(
    songId: String,
    score: ScoredRelation
  )] {
    let querySQL = """
    SELECT song_id1, song_id2, adjacency, co_membership, album, total FROM (
        SELECT song_id1, song_id2, adjacency, co_membership, album, total
        FROM scored_pairs WHERE song_id1 = ?1 AND total >= ?3
        UNION ALL
        SELECT song_id1, song_id2, adjacency, co_membership, album, total
        FROM scored_pairs WHERE song_id2 = ?1 AND total >= ?3
    ) ORDER BY total DESC LIMIT ?2
    """
    guard let statement = prepareStatement(querySQL) else { return [] }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (songId as NSString).utf8String, -1, nil)
    sqlite3_bind_int(statement, 2, Int32(limit))
    sqlite3_bind_double(statement, 3, Double(TrackAdjacencyWeights.minimumThreshold))

    var results: [(songId: String, score: ScoredRelation)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let songId1 = String(cString: sqlite3_column_text(statement, 0))
      let songId2 = String(cString: sqlite3_column_text(statement, 1))
      let adjacencyValue = Float(sqlite3_column_double(statement, 2))
      let coMembershipValue = Float(sqlite3_column_double(statement, 3))
      let albumValue = Float(sqlite3_column_double(statement, 4))

      let relation = ScoredRelation(
        songId1: songId1, songId2: songId2,
        adjacency: adjacencyValue, coMembership: coMembershipValue, album: albumValue
      )
      let otherSong = relation.otherSongId(from: songId) ?? songId2
      results.append((songId: otherSong, score: relation))
    }
    return results
  }

  public func hasData(for songId: String) -> Bool {
    let querySQL = """
    SELECT 1 FROM scored_pairs
    WHERE (song_id1 = ?1 OR song_id2 = ?1) AND total >= ?2
    LIMIT 1
    """
    guard let statement = prepareStatement(querySQL) else { return false }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (songId as NSString).utf8String, -1, nil)
    sqlite3_bind_double(statement, 2, Double(TrackAdjacencyWeights.minimumThreshold))

    return sqlite3_step(statement) == SQLITE_ROW
  }

  public func score(for songIdA: String, _ songIdB: String) -> ScoredRelation? {
    let canonicalId1 = min(songIdA, songIdB)
    let canonicalId2 = max(songIdA, songIdB)

    let querySQL =
      "SELECT adjacency, co_membership, album FROM scored_pairs WHERE song_id1 = ?1 AND song_id2 = ?2"
    guard let statement = prepareStatement(querySQL) else { return nil }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (canonicalId1 as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 2, (canonicalId2 as NSString).utf8String, -1, nil)

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    return ScoredRelation(
      songId1: canonicalId1, songId2: canonicalId2,
      adjacency: Float(sqlite3_column_double(statement, 0)),
      coMembership: Float(sqlite3_column_double(statement, 1)),
      album: Float(sqlite3_column_double(statement, 2))
    )
  }

  public func playlistCoOccurrenceCount(songIdA: String, songIdB: String) -> Int {
    guard let relation = score(for: songIdA, songIdB) else { return 0 }
    guard TrackAdjacencyWeights.coMembershipWeight > 0 else { return 0 }
    return Int(relation.coMembership / TrackAdjacencyWeights.coMembershipWeight)
  }

  // MARK: - Public Utilities

  public func hasAnyData() -> Bool {
    let querySQL = "SELECT 1 FROM scored_pairs LIMIT 1"
    guard let statement = prepareStatement(querySQL) else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  public func deleteDatabase() {
    if let databasePointer = databasePointer {
      sqlite3_close(databasePointer)
      self.databasePointer = nil
    }
    try? FileManager.default.removeItem(atPath: databasePath)
  }

  // MARK: - Private Helpers

  private func createTablesAndIndexes() {
    let schemaStatements = [
      """
      CREATE TABLE IF NOT EXISTS scored_pairs (
          song_id1 TEXT NOT NULL,
          song_id2 TEXT NOT NULL,
          adjacency REAL NOT NULL DEFAULT 0,
          co_membership REAL NOT NULL DEFAULT 0,
          album REAL NOT NULL DEFAULT 0,
          total REAL NOT NULL DEFAULT 0,
          PRIMARY KEY (song_id1, song_id2)
      ) WITHOUT ROWID
      """,
      "CREATE INDEX IF NOT EXISTS idx_song1_total ON scored_pairs (song_id1, total DESC)",
      "CREATE INDEX IF NOT EXISTS idx_song2_total ON scored_pairs (song_id2, total DESC)",
      """
      CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
      ) WITHOUT ROWID
      """,
    ]
    for sql in schemaStatements {
      execute(sql)
    }
  }

  private func execute(_ sql: String) {
    if sqlite3_exec(databasePointer, sql, nil, nil, nil) != SQLITE_OK {
      NSLog(
        "TrackAdjacencySQLiteStore: exec failed — %s",
        String(cString: sqlite3_errmsg(databasePointer))
      )
    }
  }

  private func prepareStatement(_ sql: String) -> OpaquePointer? {
    var statementPointer: OpaquePointer?
    if sqlite3_prepare_v2(databasePointer, sql, -1, &statementPointer, nil) != SQLITE_OK {
      NSLog(
        "TrackAdjacencySQLiteStore: prepare failed — %s",
        String(cString: sqlite3_errmsg(databasePointer))
      )
      return nil
    }
    return statementPointer
  }
}
