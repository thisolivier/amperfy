//
//  DeckCandidateResolver.swift
//  AmperfyKit
//
//  Turns a pool's raw ScoredCandidate (just an id + score) into the full
//  DeckCandidate the deck UI renders, by looking the collection up in
//  LibraryStorage.
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

// MARK: - DeckCandidateResolver

enum DeckCandidateResolver {
  /// Resolves one pool-tagged candidate into a full `DeckCandidate`. Returns
  /// `nil` if the collection can't be found locally (e.g. a sidecar result
  /// for a collection this device hasn't synced yet) — callers drop these
  /// silently, same as any other "pool couldn't fill the count" shortfall.
  static func resolve(
    _ tagged: PoolTaggedCandidate,
    seedRef: String,
    seedArtist: String? = nil,
    storage: LibraryStorage,
    account: Account
  )
    -> DeckCandidate? {
    let provenance = DeckProvenance(
      pool: tagged.pool,
      seedRef: seedRef,
      seedTitle: tagged.scored.seedTitle,
      seedArtist: seedArtist
    )

    switch tagged.scored.kind {
    case .album:
      guard let album = storage.getAlbum(
        for: account,
        id: tagged.scored.collectionId,
        isDetailFaultResolution: false
      ) else { return nil }
      return DeckCandidate(
        collectionId: album.id,
        kind: .album,
        title: album.name,
        subtitle: album.artist?.name,
        trackCount: album.songs.count,
        totalDuration: TimeInterval(album.duration),
        year: album.year > 0 ? album.year : nil,
        provenance: provenance
      )

    case .playlist:
      guard let playlist = storage.getPlaylist(for: account, id: tagged.scored.collectionId)
      else { return nil }
      return DeckCandidate(
        collectionId: playlist.id,
        kind: .playlist,
        title: playlist.name,
        // Playlist owner isn't modeled on `Playlist` today; design §5.2 says
        // to omit the subtitle row when unknown, so nil is the correct value
        // here, not a gap to fill.
        subtitle: nil,
        trackCount: playlist.songCount,
        totalDuration: TimeInterval(playlist.duration),
        year: nil,
        provenance: provenance
      )
    }
  }
}
