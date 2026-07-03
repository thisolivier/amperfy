@testable import AmperfyKit
import Foundation

/// Builds a `NeedleDropManifest` against the bundled stub sprite fixture
/// `AmperfyKitTests/Helper/TestAssets/needle_drop_stub_sprite.m4a`.
///
/// That file is a 9-second, mono AAC clip synthesized for this sprint: 6 sequential 1.5s
/// pure-tone slices (C4, D4, E4, F4, G4, A4) with short fades in/out at each slice boundary to
/// avoid clicks. No network call and no real sprite service are involved — this is the
/// "sample synthesized/bundled test clip" the sprint spec explicitly allows in place of a real
/// server-rendered sprite, since D3b (the sprite service itself) doesn't exist yet.
enum NeedleDropStubFixture {
  /// Marker type purely so `Bundle(for:)` can locate the test bundle the fixture asset ships in.
  private final class BundleMarker {}

  static var spriteFileURL: URL {
    guard let url = Bundle(for: BundleMarker.self).url(
      forResource: "needle_drop_stub_sprite",
      withExtension: "m4a"
    ) else {
      fatalError(
        "needle_drop_stub_sprite.m4a not found in the AmperfyKitTests bundle — check the " +
          "Resources build phase membership in project.pbxproj."
      )
    }
    return url
  }

  static func makeManifest() -> NeedleDropManifest {
    let noteNames = ["One", "Two", "Three", "Four", "Five", "Six"]
    let slices = (0 ..< 6).map { index in
      NeedleDropSlice(
        trackId: "slice-\(index + 1)",
        title: "Slice \(noteNames[index])",
        artist: "Stub Artist",
        spriteOffset: TimeInterval(index) * 1.5,
        sliceDuration: 1.5
      )
    }
    return NeedleDropManifest(
      collectionId: "stub-collection",
      spriteURL: spriteFileURL,
      slices: slices
    )
  }
}
