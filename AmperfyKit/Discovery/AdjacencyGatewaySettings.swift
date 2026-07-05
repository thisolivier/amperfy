//
//  AdjacencyGatewaySettings.swift
//  AmperfyKit
//
//  UserDefaults-backed settings for the HTTP gateway that fronts the
//  adjacency-sidecar (QA :5041 / prod :5040, static X-API-Key auth). Follows
//  the same storage pattern as AdjacencySidecarSettings. Gateway mode is
//  active only when BOTH the URL and the key are set (see
//  AdjacencyGatewayRoute); otherwise every call site keeps the legacy
//  direct-to-sidecar derivation unchanged.
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

/// Local-only gateway URL + API-key settings, backed by UserDefaults.
public final class AdjacencyGatewaySettings: @unchecked Sendable {
  public static let shared = AdjacencyGatewaySettings()

  private let urlDefaultsKey = "amperfy.fork.discovery.gatewayUrl"
  private let apiKeyDefaultsKey = "amperfy.fork.discovery.gatewayKey"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The gateway's base URL string (e.g. `http://localhost:5041`). Empty when unset.
  public var gatewayUrlString: String {
    get { defaults.string(forKey: urlDefaultsKey) ?? "" }
    set { defaults.set(newValue, forKey: urlDefaultsKey) }
  }

  /// The gateway's static `X-API-Key` value. Empty when unset.
  public var gatewayApiKey: String {
    get { defaults.string(forKey: apiKeyDefaultsKey) ?? "" }
    set { defaults.set(newValue, forKey: apiKeyDefaultsKey) }
  }

  /// Non-nil only when gateway mode is active (both URL and key usable) —
  /// the single mode decision every adjacency call site branches on.
  public var activeRoute: AdjacencyGatewayRoute? {
    AdjacencyGatewayRoute.make(urlString: gatewayUrlString, apiKey: gatewayApiKey)
  }
}
