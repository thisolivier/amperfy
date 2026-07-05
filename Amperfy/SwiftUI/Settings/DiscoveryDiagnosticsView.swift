//
//  DiscoveryDiagnosticsView.swift
//  Amperfy
//
//  Settings > Discovery Diagnostics (build-60 user feedback): surfaces the
//  DiscoveryTelemetry ring buffers (last 20 deals with per-stage timings,
//  last 40 sprite fetches) newest-first in copy-friendly form, plus a live
//  sidecar health check — so "slow deals" (which stage ate the time) and
//  "missing previews" (what URL was tried, what happened) are self-diagnosing
//  on a production device with no remote debugging.
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

import AmperfyKit
import SwiftUI

// MARK: - DiscoveryDiagnosticsView

struct DiscoveryDiagnosticsView: View {
  @State
  private var dealRecords: [DiscoveryDealRecord] = []
  @State
  private var spriteFetchRecords: [DiscoverySpriteFetchRecord] = []
  @State
  private var healthResult: String?
  @State
  private var isTestingConnection = false

  var body: some View {
    SettingsList {
      SettingsSection(content: {
        // Which path adjacency requests take right now — gateway when both
        // the Gateway URL and Key are set in Settings, direct otherwise.
        diagnosticText(
          "Active mode: " +
            (AdjacencyGatewaySettings.shared.activeRoute == nil
              ? AdjacencyRequestMode.direct.rawValue
              : AdjacencyRequestMode.gateway.rawValue)
        )
        Button {
          Task { await testSidecarConnection() }
        } label: {
          Text(isTestingConnection ? "Testing\u{2026}" : "Test Sidecar Connection")
        }
        .disabled(isTestingConnection)
        if let healthResult {
          diagnosticText(healthResult)
        }
      }, header: "Sidecar Connection")

      SettingsSection(content: {
        Button("Copy All") {
          UIPasteboard.general.string = DiscoveryTelemetry.shared.plainTextDump()
        }
        Button("Export Logs") {
          exportLogs()
        }
        Button("Refresh") {
          reload()
        }
      }, header: "Log Actions")

      SettingsSection(content: {
        if dealRecords.isEmpty {
          Text("No deals recorded yet").foregroundColor(.secondary)
        }
        ForEach(dealRecords) { record in
          diagnosticText(record.plainText)
        }
      }, header: "Deals — Newest First")

      SettingsSection(content: {
        if spriteFetchRecords.isEmpty {
          Text("No sprite fetches recorded yet").foregroundColor(.secondary)
        }
        ForEach(spriteFetchRecords) { record in
          diagnosticText(record.plainText)
        }
      }, header: "Sprite Fetches — Newest First")
    }
    .navigationTitle("Discovery Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { reload() }
  }

  private func diagnosticText(_ text: String) -> some View {
    Text(text)
      .font(.caption.monospaced())
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func reload() {
    dealRecords = DiscoveryTelemetry.shared.dealRecordsNewestFirst()
    spriteFetchRecords = DiscoveryTelemetry.shared.spriteFetchRecordsNewestFirst()
  }

  // MARK: Sidecar health check

  /// Tests whichever mode is ACTIVE: gateway mode hits
  /// `{gateway}/adjacency/health` with `X-API-Key` (401 surfaced distinctly
  /// as a rejected key); direct mode keeps the legacy sidecar health check.
  private func testSidecarConnection() async {
    isTestingConnection = true
    defer { isTestingConnection = false }
    let gatewayRoute = AdjacencyGatewaySettings.shared.activeRoute
    let mode: AdjacencyRequestMode = gatewayRoute == nil ? .direct : .gateway
    let healthURL: URL
    if let gatewayRoute {
      guard let gatewayHealthURL = gatewayRoute.url(sidecarPath: "/health") else {
        healthResult = "Could not build a gateway health URL from " +
          "'\(AdjacencyGatewaySettings.shared.gatewayUrlString)'."
        return
      }
      healthURL = gatewayHealthURL
    } else {
      guard let activeAccountInfo = appDelegate.storage.settings.accounts.active else {
        healthResult = "No active account — cannot derive the sidecar URL."
        return
      }
      let account = appDelegate.storage.main.library.getAccount(info: activeAccountInfo)
      guard let baseURL = AdjacencySidecarClient.deriveBaseURL(serverUrl: account.serverUrl)
      else {
        healthResult = "Could not derive a sidecar URL from server URL '\(account.serverUrl)'."
        return
      }
      healthURL = baseURL.appendingPathComponent("health")
    }
    var request = URLRequest(url: healthURL)
    if let gatewayRoute {
      request.setValue(
        gatewayRoute.apiKey,
        forHTTPHeaderField: AdjacencyGatewayRoute.apiKeyHeaderName
      )
    }
    let start = DispatchTime.now()
    do {
      let (_, response) = try await DiscoveryURLSession.fastFail.data(for: request)
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      healthResult = AdjacencyConnectionTest.resultText(
        urlString: healthURL.absoluteString,
        statusCode: statusCode,
        latencyMilliseconds: DiscoveryTelemetry.millisecondsSince(start),
        mode: mode
      )
    } catch {
      let elapsed = DiscoveryTelemetry.millisecondsSince(start)
      healthResult = "URL: \(healthURL.absoluteString)\nMode: \(mode.rawValue)\n" +
        "Failed after \(elapsed) ms: \(error.localizedDescription)"
    }
  }

  // MARK: Export

  /// Standard iOS share sheet with the full plaintext dump as a .txt file
  /// (AirDrop/Messages-friendly), presented UIKit-side since the deployment
  /// target predates ShareLink.
  private func exportLogs() {
    let dumpText = DiscoveryTelemetry.shared.plainTextDump()
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let temporaryFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discovery-diagnostics-\(timestamp).txt")
    do {
      try dumpText.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
    } catch {
      healthResult = "Export failed: \(error.localizedDescription)"
      return
    }
    guard let windowScene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      let rootViewController = windowScene.keyWindow?.rootViewController
    else { return }
    var presenter = rootViewController
    while let presented = presenter.presentedViewController { presenter = presented }
    let activityViewController = UIActivityViewController(
      activityItems: [temporaryFileURL],
      applicationActivities: nil
    )
    activityViewController.popoverPresentationController?.sourceView = presenter.view
    activityViewController.popoverPresentationController?
      .sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
    activityViewController.completionWithItemsHandler = { _, _, _, _ in
      try? FileManager.default.removeItem(at: temporaryFileURL)
    }
    presenter.present(activityViewController, animated: true)
  }
}
