//
//  SettingEnumerations+UIKit.swift
//  Amperfy
//
//  Bridging extensions for AmperfyKit enums that need UIKit types.
//  Created during Sep-5 UIKit removal.
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
import UIKit

// MARK: - ThemePreference + UIColor

extension ThemePreference {
  public var asColor: UIColor {
    switch self {
    case .blue:
      return .systemBlue
    case .green:
      return .systemGreen
    case .red:
      return .systemRed
    case .yellow:
      return .systemYellow
    case .orange:
      return .systemOrange
    case .purple:
      return .systemPurple
    }
  }

  public var contrastColor: UIColor {
    switch self {
    case .blue:
      return .white
    case .green:
      return .white
    case .red:
      return .white
    case .yellow:
      return .black
    case .orange:
      return .white
    case .purple:
      return .white
    }
  }
}

// MARK: - AppearanceStyle + UIUserInterfaceStyle

extension AppearanceStyle {
  public var asUIUserInterfaceStyle: UIUserInterfaceStyle {
    UIUserInterfaceStyle(rawValue: rawValue) ?? .unspecified
  }

  public init(from uiStyle: UIUserInterfaceStyle) {
    self = AppearanceStyle(rawValue: uiStyle.rawValue) ?? .unspecified
  }
}

// MARK: - FetchResult + UIBackgroundFetchResult

extension FetchResult {
  public var asUIBackgroundFetchResult: UIBackgroundFetchResult {
    switch self {
    case .newData: return .newData
    case .noData: return .noData
    case .failed: return .failed
    }
  }

  public init(from uiResult: UIBackgroundFetchResult) {
    switch uiResult {
    case .newData: self = .newData
    case .noData: self = .noData
    case .failed: self = .failed
    @unknown default: self = .failed
    }
  }
}
