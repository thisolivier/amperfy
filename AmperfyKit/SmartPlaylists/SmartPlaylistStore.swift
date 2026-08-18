//
//  SmartPlaylistStore.swift
//  AmperfyKit
//
//  UserDefaults persistence for the FROZEN smart playlist result
//  (V1 spec, 2026-08-17). Mirrors the Codable-blob pattern of GigsSettings.
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

import CoreData
import Foundation

// MARK: - SmartPlaylistState

/// One frozen smart playlist: the query that produced it, the ordered result,
/// and the provenance the results screen shows next to the refresh button.
///
/// The result list is deliberately FROZEN — it never re-evaluates itself on
/// launch or on library change. Only an explicit refresh replaces it.
public struct SmartPlaylistState: Codable, Equatable, Sendable {
  /// The rules that produced `frozenSongIds`.
  public var query: SmartPlaylistQuery
  /// Canonical song ids in result order (`addedDate` DESC, then title).
  public var frozenSongIds: [String]
  /// When this result was generated.
  public var refreshedAt: Date
  /// `true` when the refresh ran without a server round-trip, so the result may
  /// be missing recently-added songs the device has not seen yet.
  public var wasOfflineRefresh: Bool
  /// Footer note input: songs excluded solely because their added-date is
  /// unknown. See `SmartPlaylistEvaluation.songsMissingAddedDate`.
  public var songsMissingAddedDate: Int

  public init(
    query: SmartPlaylistQuery,
    frozenSongIds: [String],
    refreshedAt: Date,
    wasOfflineRefresh: Bool,
    songsMissingAddedDate: Int
  ) {
    self.query = query
    self.frozenSongIds = frozenSongIds
    self.refreshedAt = refreshedAt
    self.wasOfflineRefresh = wasOfflineRefresh
    self.songsMissingAddedDate = songsMissingAddedDate
  }
}

// MARK: - SmartPlaylistStore

/// Persists the current smart playlist across launches.
///
/// V1 keeps a single "current" state, but every entry point takes or returns a
/// whole `SmartPlaylistState`, so V2's saved-smart-playlist list is a matter of
/// adding a keyed variant of `save`/`load` beside these — no call-site churn.
public final class SmartPlaylistStore: @unchecked Sendable {
  public static let shared = SmartPlaylistStore()

  /// Namespaced like every other fork-added setting, so it can never collide
  /// with an upstream Amperfy key.
  static let currentStateKey = "amperfy.fork.smartPlaylists.currentState"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Persistence

  /// Stores the state as the current smart playlist. Silently no-ops if
  /// encoding fails — a persistence hiccup must never break a refresh that
  /// already produced a usable in-memory result.
  public func save(_ state: SmartPlaylistState) {
    guard let data = try? Self.makeEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.currentStateKey)
  }

  /// The stored state, or `nil` when nothing has been saved yet (first use) or
  /// the blob is undecodable (e.g. a rule model from a future version).
  public func loadCurrentState() -> SmartPlaylistState? {
    guard let data = defaults.data(forKey: Self.currentStateKey) else { return nil }
    return try? Self.makeDecoder().decode(SmartPlaylistState.self, from: data)
  }

  /// Whether a smart playlist has been built at all. The results screen uses
  /// this to decide whether to open straight into the builder.
  public var hasStoredState: Bool {
    defaults.data(forKey: Self.currentStateKey) != nil
  }

  public func clear() {
    defaults.removeObject(forKey: Self.currentStateKey)
  }

  // MARK: - Rehydration

  /// Resolves the frozen ids back into songs with ONE `id IN %@` fetch, then
  /// re-sorts into the stored id order (Core Data returns no meaningful order
  /// for an `IN` fetch). Ids that no longer resolve — the song was deleted
  /// server-side and is not cached — are dropped silently: a frozen list must
  /// degrade quietly rather than surface ghost rows.
  public func resolveSongs(
    forIds songIds: [String],
    context: NSManagedObjectContext,
    account: Account
  )
    -> [SongMO] {
    guard !songIds.isEmpty else { return [] }
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "%K IN %@", #keyPath(SongMO.id), songIds),
      NSPredicate(format: "account == %@", account.managedObject.objectID),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    let fetched = (try? context.fetch(fetchRequest)) ?? []

    var songsById = [String: SongMO]()
    for song in fetched {
      songsById[song.id] = song
    }
    return songIds.compactMap { songsById[$0] }
  }

  /// Convenience overload: resolve the songs of a stored state.
  public func resolveSongs(
    for state: SmartPlaylistState,
    context: NSManagedObjectContext,
    account: Account
  )
    -> [SongMO] {
    resolveSongs(forIds: state.frozenSongIds, context: context, account: account)
  }

  // MARK: - Coders

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
