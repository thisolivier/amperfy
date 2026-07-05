//
//  SettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

// MARK: - SettingsView

struct SettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  func screenLockPreventionOffPressed() {
    settings.screenLockPreventionPreference = .never
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionOnPressed() {
    settings.screenLockPreventionPreference = .always
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionChargingPressed() {
    settings.screenLockPreventionPreference = .onlyIfCharging
    UIDevice.current.isBatteryMonitoringEnabled = true
    appDelegate.configureLockScreenPrevention()
  }

  private static let lastViewedBuildKey = "amperfy.fork.lastViewedBuildNumber"

  private var hasUnseenReleaseNotes: Bool {
    let lastViewed = UserDefaults.standard.integer(forKey: Self.lastViewedBuildKey)
    let currentBuild = Int(AppDelegate.buildNumber) ?? 0
    return currentBuild > lastViewed
  }

  func navigationLink(_ item: NavigationTarget) -> some View {
    NavigationLink(destination: AnyView(item.view()).onAppear {
      if item == .whatsNew {
        let currentBuild = Int(AppDelegate.buildNumber) ?? 0
        UserDefaults.standard.set(currentBuild, forKey: Self.lastViewedBuildKey)
      }
    }) {
      HStack {
        Text(item.displayName)
        if item == .whatsNew, hasUnseenReleaseNotes {
          Spacer()
          Text("NEW")
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
        }
      }
    }
  }

  var body: some View {
    let list =
      SettingsList {
        SettingsSection {
          SettingsRow(title: "Version") {
            SecondaryText(AppDelegate.version)
          }
          SettingsRow(title: "Build Number") {
            SecondaryText(AppDelegate.buildNumber)
          }
        }

        SettingsSection {
          SettingsCheckBoxRow(title: "Offline Mode", isOn: $settings.isOfflineMode)
          // PR 21: inline descriptor INSIDE the same rounded-inset
          // section as the toggle so the pair reads as one unified
          // grouped container. Replaces the janky free-floating
          // uppercase `footer:` caption that used to sit below.
          InlineFooterRow(
            text: "Songs, podcasts, and artworks won’t download offline. Searches are limited to the device, and playlists won’t sync with the server."
          )
        }

        SettingsSection {
          SettingsRow(title: "Prevent Screen Lock") {
            Menu(settings.screenLockPreventionPreference.description) {
              Button(
                ScreenLockPreventionPreference.never.description,
                action: screenLockPreventionOffPressed
              )
              Button(
                ScreenLockPreventionPreference.always.description,
                action: screenLockPreventionOnPressed
              )
              Button(
                ScreenLockPreventionPreference.onlyIfCharging.description,
                action: screenLockPreventionChargingPressed
              )
            }
          }
        }

        #if !targetEnvironment(macCatalyst) // ok
          SettingsSection {
            navigationLink(.whatsNew)
          }

          SettingsSection {
            // PR 20.4: Custom Theme promoted to a top-level Settings
            // row. Placed as the first entry of the existing nav-link
            // cluster for visual prominence (above Account).
            navigationLink(.customTheme)
            navigationLink(.account)
            navigationLink(.displayAndInteraction)
            navigationLink(.library)
            navigationLink(.player)
            navigationLink(.equalizer)
            navigationLink(.swipe)
            navigationLink(.artwork)
          }

          SettingsSection {
            navigationLink(.support)
            navigationLink(.license)
            navigationLink(.xcallback)
            // Fork addition (build-60): production-device Discovery
            // debuggability — deal timings, sprite-fetch outcomes,
            // sidecar health check.
            navigationLink(.discoveryDiagnostics)

            #if DEBUG
              navigationLink(.developer)
            #endif
          }
        #endif
      }

    #if targetEnvironment(macCatalyst) // ok
      ZStack {
        list
      }
      .navigationTitle("General")
      .navigationBarTitleDisplayMode(.inline)
    #else
      NavigationView {
        list
          .navigationTitle("Settings")
      }
      .navigationViewStyle(.stack)
    #endif
  }
}

// MARK: - SettingsView_Previews

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}
