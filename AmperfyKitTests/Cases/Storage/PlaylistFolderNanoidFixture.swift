//
//  PlaylistFolderNanoidFixture.swift
//  AmperfyKitTests
//
//  Created by the Amperfy fork (Feature G — Playlist folders).
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

/// Folder ids shaped the way the real server makes them.
///
/// Navidrome mints folder ids with `id.NewRandom()` — a 22-character nanoid over
/// `[0-9A-Za-z]`. They are **not** UUIDs and cannot be parsed as one, which is
/// the whole reason folder identity is an opaque string: an earlier client
/// parsed the id into a `UUID` and fell back to a freshly minted random one when
/// the parse failed, so against a real server every folder silently changed
/// identity on each rebuild of the tree.
///
/// Tests seed ids through this fixture rather than reaching for
/// `UUID().uuidString`, so nothing can quietly start depending on the UUID shape
/// again.
enum PlaylistFolderNanoidFixture {
  private static let alphabet = Array(
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  )

  static let idLength = 22

  /// A random server-shaped folder id.
  static func make() -> String {
    String((0 ..< idLength).map { _ in alphabet.randomElement()! })
  }

  /// A deterministic server-shaped id built from `seed`, padded to the real
  /// length. Useful when a test needs to name the same folder twice.
  static func make(seed: String) -> String {
    let padding = String(repeating: "0", count: max(0, idLength - seed.count))
    return String((seed + padding).prefix(idLength))
  }
}
