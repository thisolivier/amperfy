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
    // Single shared mode decision (gateway when BOTH URL + key are set):
    // gateway mode routes {gateway}/adjacency/sprite-manifest with X-API-Key;
    // direct mode keeps the legacy host:port derivation unchanged.
    let gatewayRoute = AdjacencyGatewaySettings.shared.activeRoute
    let mode: AdjacencyRequestMode = gatewayRoute == nil ? .direct : .gateway
    guard let url = manifestURL(
      collectionId: collectionId,
      kind: kind,
      account: account,
      gatewayRoute: gatewayRoute
    ) else {
      DiscoveryTelemetry.shared.recordSpriteFetch(
        urlString: "(unresolvable — bad server URL)",
        outcome: "failed (no URL) mode=\(mode.rawValue)",
        milliseconds: 0
      )
      return .failed
    }
    // Fast-fail session (5s request timeout) + X-Deal-Id correlation header —
    // an unreachable sidecar must degrade the preview quickly, not stall it
    // behind URLSession.shared's 60s default.
    var request = URLRequest(url: url)
    if let dealId = DiscoveryTelemetry.shared.currentDealId {
      request.setValue(dealId, forHTTPHeaderField: DiscoveryTelemetry.dealIdHeaderName)
    }
    if let gatewayRoute {
      request.setValue(
        gatewayRoute.apiKey,
        forHTTPHeaderField: AdjacencyGatewayRoute.apiKeyHeaderName
      )
    }
    let fetchStart = DispatchTime.now()
    func record(_ outcome: String) {
      DiscoveryTelemetry.shared.recordSpriteFetch(
        urlString: url.absoluteString,
        outcome: "\(outcome) mode=\(mode.rawValue)",
        milliseconds: DiscoveryTelemetry.millisecondsSince(fetchStart)
      )
    }
    do {
      let (data, response) = try await DiscoveryURLSession.fastFail.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        record("failed (non-HTTP response)")
        return .failed
      }
      // 404 = not-yet-rendered = Unavailable, not an error (contract §5, design §5.3).
      if http.statusCode == 404 {
        record("unavailable (404 not-yet-rendered)")
        return .unavailable
      }
      guard (200 ..< 300).contains(http.statusCode) else {
        record("failed (status \(http.statusCode))")
        return .failed
      }
      let manifest = try JSONDecoder().decode(NeedleDropManifest.self, from: data)
      record("ready (\(manifest.slices.count) slices)")
      // Contract §3.3 allows spriteUrl to be relative ("/sprite-audio?...").
      // A relative URL decodes fine but AVPlayer silently can't load it — no
      // request, no audio — so resolve it against the URL we fetched from.
      // Gateway mode: naive resolution against the manifest URL would drop
      // the "/adjacency" prefix (a leading-slash relative path replaces the
      // whole path), so rebase the sprite URL through the gateway instead:
      // "/sprite-audio?..." -> "{gateway}/adjacency/sprite-audio?...".
      if let gatewayRoute {
        guard let rebasedSpriteURL = gatewayRoute.url(rebasing: manifest.spriteURL) else {
          record("failed (could not rebase sprite URL through gateway)")
          return .failed
        }
        return .ready(NeedleDropManifest(
          collectionId: manifest.collectionId,
          spriteURL: rebasedSpriteURL,
          slices: manifest.slices
        ))
      }
      return .ready(manifest.resolvingSpriteURL(against: url))
    } catch {
      record("failed (\(error.localizedDescription))")
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
    account: Account,
    gatewayRoute: AdjacencyGatewayRoute?
  )
    -> URL? {
    let queryItems = [
      URLQueryItem(name: "collectionId", value: collectionId),
      URLQueryItem(name: "kind", value: kind.rawValue),
    ]
    if let gatewayRoute {
      return gatewayRoute.url(sidecarPath: "/sprite-manifest", queryItems: queryItems)
    }
    guard let host = URL(string: account.serverUrl)?.host else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = AdjacencySidecarSettings.shared.port
    components.path = "/sprite-manifest"
    components.queryItems = queryItems
    return components.url
  }
}
