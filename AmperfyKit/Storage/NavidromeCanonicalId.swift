//
//  NavidromeCanonicalId.swift
//  AmperfyKit
//
//  Created for the 2026-09-28 server id migration (upstream canonical ids).
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

import CryptoKit
import Foundation
import os.log

/// The server's canonical-id transform, reimplemented byte-for-byte.
///
/// Navidrome's `uniform_canonical_ids` migration re-encodes every 22-char
/// base62 id whose numeric value exceeds 128 bits as
/// `base62(md5(oldId))`, zero-padded to 22 chars — using Go's
/// `big.Int.Text(62)` digit alphabet (0-9, then LOWERCASE, then UPPERCASE).
/// Ids that already fit 128 bits, and any other shape, pass through
/// unchanged. Because the transform is deterministic, a client can compute
/// the server's new id for anything it holds locally — which is what lets
/// downloaded files (named by song id on disk) be relinked instead of
/// orphaned when the server migrates.
///
/// Verified against six real (old, new) pairs extracted from the production
/// database before/after the actual migration — see
/// `NavidromeCanonicalIdTest`.
public enum NavidromeCanonicalId {
  /// Go's `big.Int.Text(62)` digit set. NOT the 0-9A-Za-z order Navidrome
  /// uses for nanoid GENERATION — encoding and generation use different
  /// alphabets, and the migration output follows this one.
  private static let goBase62Alphabet =
    Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
  private static let goBase62IndexByCharacter: [Character: Int] = {
    var indexByCharacter = [Character: Int]()
    for (index, character) in goBase62Alphabet.enumerated() {
      indexByCharacter[character] = index
    }
    return indexByCharacter
  }()

  /// The server's new id for `id` after the canonical-id migration.
  /// Returns `id` unchanged whenever the migration would have.
  public static func canonicalized(_ id: String) -> String {
    guard id.count == 22 else { return id }
    guard let valueBytes = parseBase62ToBytes(id) else { return id }
    guard valueBytes.count > 16 else { return id } // fits 128 bits — kept
    let digest = Insecure.MD5.hash(data: Data(id.utf8))
    return encodeBase62(bytes: Array(digest))
  }

  /// Minimal big-endian byte representation of a base62 string under Go's
  /// alphabet, or nil if any character is outside the alphabet.
  private static func parseBase62ToBytes(_ base62String: String) -> [UInt8]? {
    var valueBytes = [UInt8]() // big-endian, no leading zeros
    for character in base62String {
      guard let digit = goBase62IndexByCharacter[character] else { return nil }
      // valueBytes = valueBytes * 62 + digit
      var carry = digit
      for byteIndex in stride(from: valueBytes.count - 1, through: 0, by: -1) {
        let product = Int(valueBytes[byteIndex]) * 62 + carry
        valueBytes[byteIndex] = UInt8(product & 0xFF)
        carry = product >> 8
      }
      while carry > 0 {
        valueBytes.insert(UInt8(carry & 0xFF), at: 0)
        carry >>= 8
      }
    }
    return valueBytes
  }

  /// `fmt.Sprintf("%022s", big.Int.SetBytes(bytes).Text(62))`, faithfully.
  private static func encodeBase62(bytes: [UInt8]) -> String {
    var remaining = bytes
    var digits = [Character]()
    while remaining.contains(where: { $0 != 0 }) {
      var remainder = 0
      var quotient = [UInt8]()
      for byte in remaining {
        let accumulator = remainder << 8 + Int(byte)
        quotient.append(UInt8(accumulator / 62))
        remainder = accumulator % 62
      }
      while quotient.first == 0 { quotient.removeFirst() }
      digits.append(goBase62Alphabet[remainder])
      remaining = quotient
    }
    let encoded = String(digits.reversed())
    return String(repeating: "0", count: max(0, 22 - encoded.count)) + encoded
  }

  // MARK: - Cache-file relinking

  private static let log = OSLog(subsystem: "Amperfy", category: "CanonicalIdRelink")

  /// Rename every id-keyed file in `directoryURL` (`<id>.<ext>` or bare
  /// `<id>`) to its canonicalized id, so a forced resync re-adopts the file
  /// under the id the migrated server now serves. Skips files whose id is
  /// unchanged and never overwrites an existing destination. Returns how many
  /// files were renamed.
  @discardableResult
  public static func relinkFiles(
    in directoryURL: URL,
    fileManager: FileManager = .default
  )
    -> Int {
    guard let fileURLs = try? fileManager.contentsOfDirectory(
      at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return 0 }

    var renamedCount = 0
    for fileURL in fileURLs {
      let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?
        .isDirectory ?? false
      guard !isDirectory else { continue }
      let fileName = fileURL.lastPathComponent
      let pathExtension = fileURL.pathExtension
      let stem = pathExtension.isEmpty
        ? fileName
        : (fileName as NSString).deletingPathExtension
      let canonicalStem = canonicalized(stem)
      guard canonicalStem != stem else { continue }
      let newFileName = pathExtension.isEmpty
        ? canonicalStem
        : "\(canonicalStem).\(pathExtension)"
      let destinationURL = directoryURL.appendingPathComponent(newFileName)
      guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
      do {
        try fileManager.moveItem(at: fileURL, to: destinationURL)
        renamedCount += 1
      } catch {
        os_log(
          "Relink failed for %{public}s: %{public}s",
          log: log, type: .error, fileName, error.localizedDescription
        )
      }
    }
    return renamedCount
  }
}
