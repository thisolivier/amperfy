import Foundation

// MARK: - NeedleDropSlice

/// One pre-rendered "needle-drop" preview slice for a single track within a collection's
/// preview sprite audio file.
///
/// Mirrors one entry of the `tracks` array returned by the adjacency-sidecar's
/// `GET /sprite-manifest` endpoint 1:1 (see `docs/contracts/adjacency-sidecar-api.md` §3.3).
/// `generatedAt` from that response is server bookkeeping the client has no use for and is
/// intentionally omitted here.
public struct NeedleDropSlice: Equatable, Identifiable, Sendable {
  public var id: String { trackId }

  public let trackId: String
  public let title: String
  public let artist: String

  /// Offset, in seconds, into the concatenated sprite audio file where this track's slice
  /// begins.
  public let spriteOffset: TimeInterval

  /// Duration, in seconds, of this track's slice within the sprite.
  public let sliceDuration: TimeInterval

  public init(
    trackId: String,
    title: String,
    artist: String,
    spriteOffset: TimeInterval,
    sliceDuration: TimeInterval
  ) {
    self.trackId = trackId
    self.title = title
    self.artist = artist
    self.spriteOffset = spriteOffset
    self.sliceDuration = sliceDuration
  }
}

// MARK: Decodable

extension NeedleDropSlice: Decodable {
  private enum CodingKeys: String, CodingKey {
    case trackId, title, artist, spriteOffset, sliceDuration
  }
}

// MARK: - NeedleDropManifest

/// Client-side representation of a collection's preview sprite: a single concatenated audio
/// file plus the ordered list of per-track slices within it.
///
/// Mirrors the response shape of `GET /sprite-manifest`
/// (`docs/contracts/adjacency-sidecar-api.md` §3.3) 1:1 aside from `generatedAt`:
/// `{collectionId, spriteUrl, tracks: [...]}` maps to `{collectionId, spriteURL, slices}` below.
public struct NeedleDropManifest: Equatable, Sendable {
  public let collectionId: String
  public let spriteURL: URL
  public let slices: [NeedleDropSlice]

  public init(collectionId: String, spriteURL: URL, slices: [NeedleDropSlice]) {
    self.collectionId = collectionId
    self.spriteURL = spriteURL
    self.slices = slices
  }
}

// MARK: Decodable

extension NeedleDropManifest: Decodable {
  private enum CodingKeys: String, CodingKey {
    case collectionId
    case spriteURL = "spriteUrl"
    case slices = "tracks"
  }
}
