//
//  GigsLocationProvider.swift
//  Amperfy
//
//  Thin CoreLocation wrapper for the Gigs "Near me" action (spec §1.3). This is
//  the app's FIRST CoreLocation use: whenInUse only, requested lazily on tap —
//  never at launch. A single one-shot fix is requested; we do not keep tracking.
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

import CoreLocation
import Foundation

// MARK: - GigsLocationError

enum GigsLocationError: Error {
  case denied
  case unavailable
}

// MARK: - GigsLocationProvider

/// Requests whenInUse authorization (if needed) and a single location fix.
/// Retains itself for the lifetime of one request so the delegate stays alive.
///
/// The class is main-actor-isolated. The manager is created on the main thread,
/// so CoreLocation delivers its callbacks on the main run loop; the nonisolated
/// delegate methods therefore use `MainActor.assumeIsolated` to reach isolated
/// state without hopping (and thus without sending non-Sendable `self` across
/// actors).
@MainActor
final class GigsLocationProvider: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var completion: ((Result<CLLocationCoordinate2D, Error>) -> ())?
  private var selfReference: GigsLocationProvider?
  private var timeoutTask: Task<(), Never>?

  /// How long to wait for a fix (or an authorization decision) before giving up
  /// with `.unavailable`. CoreLocation can silently never call back — e.g. the
  /// user leaves the system permission prompt on screen, or a fix never lands
  /// indoors — which previously hung the "Near me" flow forever (QA A4). The
  /// caller gets a clear failure it can surface instead of a stuck spinner.
  private static let requestTimeoutSeconds: UInt64 = 12

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
  }

  /// Request one location fix, prompting for whenInUse authorization lazily.
  /// A single in-flight request is enforced by the caller (GigsVC disables the
  /// button); if one is already pending here we ignore the re-entry rather than
  /// overwriting the live completion/selfReference (which would leak the first
  /// caller's continuation).
  func requestLocation(completion: @escaping (Result<CLLocationCoordinate2D, Error>) -> ()) {
    guard self.completion == nil else { return }
    self.completion = completion
    selfReference = self // keep alive until we finish
    startTimeout()

    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      manager.requestLocation()
    case .denied, .restricted:
      finish(.failure(GigsLocationError.denied))
    @unknown default:
      finish(.failure(GigsLocationError.unavailable))
    }
  }

  private func startTimeout() {
    timeoutTask?.cancel()
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.requestTimeoutSeconds * 1_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.completion != nil else { return }
        self.finish(.failure(GigsLocationError.unavailable))
      }
    }
  }

  private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
    timeoutTask?.cancel()
    timeoutTask = nil
    completion?(result)
    completion = nil
    selfReference = nil
  }

  // MARK: - CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    MainActor.assumeIsolated {
      switch status {
      case .authorizedAlways, .authorizedWhenInUse:
        // Only act on the transition once a request is pending.
        if completion != nil { self.manager.requestLocation() }
      case .denied, .restricted:
        if completion != nil { finish(.failure(GigsLocationError.denied)) }
      case .notDetermined:
        break
      @unknown default:
        if completion != nil { finish(.failure(GigsLocationError.unavailable)) }
      }
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    let coordinate = locations.last?.coordinate
    MainActor.assumeIsolated {
      guard let coordinate else {
        finish(.failure(GigsLocationError.unavailable))
        return
      }
      finish(.success(coordinate))
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    MainActor.assumeIsolated {
      finish(.failure(error))
    }
  }
}
