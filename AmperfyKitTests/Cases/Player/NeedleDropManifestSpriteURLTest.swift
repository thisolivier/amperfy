//
//  NeedleDropManifestSpriteURLTest.swift
//  AmperfyKitTests
//
//  Regression tests for resolvingSpriteURL(against:) — the sidecar's manifest
//  carries a server-relative spriteUrl ("/sprite-audio?...", contract §3.3),
//  which URL(string:) decodes without complaint but AVPlayer silently cannot
//  load (no scheme/host → no request, no audio). Found during the Discovery
//  epic's solo QA round: the needle-drop state machine ran while zero audio
//  played, because the player URL never resolved.
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

@testable import AmperfyKit
import XCTest

class NeedleDropManifestSpriteURLTest: XCTestCase {
  private let manifestFetchURL =
    URL(string: "http://localhost:8788/sprite-manifest?collectionId=abc&kind=playlist")!

  private func decodeManifest(spriteUrl: String) throws -> NeedleDropManifest {
    let json = """
    {
      "collectionId": "abc",
      "spriteUrl": "\(spriteUrl)",
      "tracks": [
        {"trackId": "t1", "title": "T", "artist": "A", "spriteOffset": 0.0, "sliceDuration": 1.5}
      ]
    }
    """
    return try JSONDecoder().decode(NeedleDropManifest.self, from: Data(json.utf8))
  }

  func testRelativeSpriteUrlResolvesAgainstManifestURL() throws {
    let manifest = try decodeManifest(spriteUrl: "/sprite-audio?collectionId=abc&kind=playlist")

    // Documents the trap: the relative form decodes, but has no scheme/host.
    XCTAssertNil(manifest.spriteURL.scheme)

    let resolved = manifest.resolvingSpriteURL(against: manifestFetchURL)
    XCTAssertEqual(
      resolved.spriteURL.absoluteString,
      "http://localhost:8788/sprite-audio?collectionId=abc&kind=playlist"
    )
  }

  func testAbsoluteSpriteUrlIsLeftUnchanged() throws {
    let manifest = try decodeManifest(spriteUrl: "http://cdn.example:9000/sprites/abc.aac")

    let resolved = manifest.resolvingSpriteURL(against: manifestFetchURL)
    XCTAssertEqual(
      resolved.spriteURL.absoluteString,
      "http://cdn.example:9000/sprites/abc.aac"
    )
  }
}
