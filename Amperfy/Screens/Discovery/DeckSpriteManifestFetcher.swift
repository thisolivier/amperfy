import AmperfyKit
import Foundation

// MARK: - AuditionDeckSpritePort

/// `AdjacencySidecarSettings` (the data-layer agent's expected settings type) did not exist
/// anywhere in the tree when this file was written, so there was nothing to read a configured
/// port from. Falls back to the documented prod port (`docs/contracts/adjacency-sidecar-api.md`
/// §1, `CLAUDE.md`'s infra table). See `DeckSpriteManifestFetcher`'s doc comment for the fuller
/// reasoning on why this sprint wrote its own fetch instead of depending on that not-yet-built
/// type's exact method signature.
enum AuditionDeckSpritePort {
  /// TODO(integration): replace with `AdjacencySidecarSettings.shared.port` once that type lands,
  /// so QA (port 8788) resolves correctly too — this constant only ever resolves prod.
  static let value = 8787
}

// MARK: - DeckSpriteManifestResult

enum DeckSpriteManifestResult: Equatable {
  case ready(NeedleDropManifest)
  case unavailable
  case failed
}

// MARK: - DeckSpriteManifestFetcher

/// Fetches a real `GET /sprite-manifest` per card (design §5.3/§9, contract §3.3), decoding
/// straight into D3a's `NeedleDropManifest` (already `Decodable`, already mirrors the response
/// shape 1:1 — no intermediate DTO needed).
///
/// **Why this writes its own fetch instead of reusing the data-layer agent's
/// `AdjacencySidecarClient`:** that type lives in `AmperfyKit/Discovery/` (off-limits — "other
/// agent's data layer, you only consume its public types") and did not exist as a file anywhere
/// in the tree at the time this was written, let alone with a settled method for sprite
/// manifests. Depending on a guessed method name/signature on a not-yet-built type would be
/// *more* fragile than a dozen self-contained lines against the (already-frozen, already-written-
/// down) HTTP contract. If `AdjacencySidecarClient` grows a sprite-manifest method during
/// integration, this whole `enum` can be deleted in favor of it — nothing outside this file
/// depends on its internals, only on `DeckSpriteManifestResult`.
enum DeckSpriteManifestFetcher {
  static func fetch(
    collectionId: String,
    kind: DeckCandidateKind,
    account: Account
  ) async -> DeckSpriteManifestResult {
    guard let url = manifestURL(collectionId: collectionId, kind: kind, account: account) else {
      return .failed
    }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse else { return .failed }
      // 404 = not-yet-rendered = Unavailable, not an error (contract §5, design §5.3).
      if http.statusCode == 404 { return .unavailable }
      guard (200 ..< 300).contains(http.statusCode) else { return .failed }
      let manifest = try JSONDecoder().decode(NeedleDropManifest.self, from: data)
      return .ready(manifest)
    } catch {
      return .failed
    }
  }

  /// Host from the active account's server URL, port from `AuditionDeckSpritePort` — mirrors the
  /// base-URL derivation the prompt describes for `AdjacencySidecarClient`
  /// (`http://{host}:{port}`, contract §1).
  private static func manifestURL(
    collectionId: String,
    kind: DeckCandidateKind,
    account: Account
  ) -> URL? {
    guard let host = URL(string: account.serverUrl)?.host else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = AuditionDeckSpritePort.value
    components.path = "/sprite-manifest"
    components.queryItems = [
      URLQueryItem(name: "collectionId", value: collectionId),
      URLQueryItem(name: "kind", value: kind.rawValue),
    ]
    return components.url
  }
}
