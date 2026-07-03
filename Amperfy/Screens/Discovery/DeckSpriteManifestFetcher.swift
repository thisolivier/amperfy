import AmperfyKit
import Foundation

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
/// `@MainActor`: its only caller, `AuditionDeckCardAuditionModel`, is itself `@MainActor` — see
/// `DeckFusionEngine.deal`'s doc comment (`AmperfyKit/Discovery/DeckFusionEngine.swift`) for the
/// same reasoning applied to the other spot in this sprint where a non-`Sendable` `Account` is
/// read synchronously by a caller-isolated async function.
@MainActor
enum DeckSpriteManifestFetcher {
  static func fetch(
    collectionId: String,
    kind: DeckCandidateKind,
    account: Account
  ) async
    -> DeckSpriteManifestResult {
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
      // Contract §3.3 allows spriteUrl to be relative ("/sprite-audio?...").
      // A relative URL decodes fine but AVPlayer silently can't load it — no
      // request, no audio — so resolve it against the URL we fetched from.
      return .ready(manifest.resolvingSpriteURL(against: url))
    } catch {
      return .failed
    }
  }

  /// Host from the active account's server URL, port from `AdjacencySidecarSettings.shared`
  /// (integration pass: this previously hardcoded 8787, which resolved prod but not QA's 8788)
  /// — mirrors the base-URL derivation `AdjacencySidecarClient` uses (`http://{host}:{port}`,
  /// contract §1).
  private static func manifestURL(
    collectionId: String,
    kind: DeckCandidateKind,
    account: Account
  )
    -> URL? {
    guard let host = URL(string: account.serverUrl)?.host else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = AdjacencySidecarSettings.shared.port
    components.path = "/sprite-manifest"
    components.queryItems = [
      URLQueryItem(name: "collectionId", value: collectionId),
      URLQueryItem(name: "kind", value: kind.rawValue),
    ]
    return components.url
  }
}
