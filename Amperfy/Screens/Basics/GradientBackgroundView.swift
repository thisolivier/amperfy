//
//  GradientBackgroundView.swift
//  Amperfy
//
//  Created by the Amperfy spike (PR 17.2 — Gradient backgrounds).
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
import UIKit

// MARK: - GradientBackgroundView

/// Thin `CAGradientLayer` wrapper installed as a `UIScrollView.backgroundView`
/// (or a stand-alone subview) to paint a user-configured gradient behind
/// the main app and album-detail surfaces. GPU-composited, zero per-frame
/// CPU cost, auto-resizes via the `layerClass` override — cheaper than
/// drawing per-frame in `draw(_:)` and cheaper than a SwiftUI
/// `LinearGradient` hosted through a `UIHostingController`.
final class GradientBackgroundView: UIView {
  override static var layerClass: AnyClass { CAGradientLayer.self }

  var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

  /// The gradient currently displayed. Setting a new value re-applies
  /// colors + direction immediately.
  var gradient: ThemeGradient {
    didSet { applyCurrentGradient() }
  }

  init(gradient: ThemeGradient) {
    self.gradient = gradient
    super.init(frame: .zero)
    // The gradient is purely decorative — we do not want to block
    // taps/scrolls on whatever view hosts us as a background.
    isUserInteractionEnabled = false
    // `backgroundColor` is the outer-view paint (visible if the gradient
    // has a transparent stop). Keep it clear — the CAGradientLayer paints
    // the full bounds.
    backgroundColor = .clear
    applyCurrentGradient()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func applyCurrentGradient() {
    gradientLayer.colors = gradient.colors.compactMap { UIColor(hex: $0)?.cgColor }
    let (start, end) = Self.points(for: gradient.direction)
    gradientLayer.startPoint = start
    gradientLayer.endPoint = end
  }

  private static func points(for direction: ThemeGradient.Direction) -> (CGPoint, CGPoint) {
    switch direction {
    case .topToBottom:
      return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
    case .bottomToTop:
      return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
    case .leftToRight:
      return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
    case .rightToLeft:
      return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
    case .topLeftToBottomRight:
      return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
    case .topRightToBottomLeft:
      return (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
    }
  }
}

// MARK: - UIViewController helper

extension UIViewController {
  /// PR 17.2: install the appropriate background surface (gradient view
  /// or solid color) on the given table view based on the current
  /// ThemeStore gradient state for the current interface style.
  ///
  /// - When a gradient is active for the VC's trait collection, sets
  ///   `tableView.backgroundColor = .clear` and installs a fresh
  ///   `GradientBackgroundView` as `tableView.backgroundView`.
  /// - When no gradient is active, clears the backgroundView and restores
  ///   the flat `.backgroundColor` path used pre-PR-17.2.
  ///
  /// Callers should invoke this in `viewDidLoad()` where they previously
  /// set `tableView.backgroundColor = .backgroundColor`, and also on
  /// any `ThemeStore.didChangeNotification` (so toggling the gradient
  /// flag in Settings updates the view without requiring a VC reload).
  func applyBackgroundSurface(to tableView: UITableView) {
    let style = traitCollection.userInterfaceStyle
    if let gradient = ThemeStore.shared.resolvedGradient(for: style) {
      tableView.backgroundColor = .clear
      // Reuse existing GradientBackgroundView when possible — avoids
      // dropping + re-creating a CAGradientLayer on every notification.
      if let existing = tableView.backgroundView as? GradientBackgroundView {
        existing.gradient = gradient
      } else {
        tableView.backgroundView = GradientBackgroundView(gradient: gradient)
      }
    } else {
      tableView.backgroundView = nil
      tableView.backgroundColor = .backgroundColor
    }
  }

  /// Collection-view overload. Same contract as the UITableView variant.
  func applyBackgroundSurface(to collectionView: UICollectionView) {
    let style = traitCollection.userInterfaceStyle
    if let gradient = ThemeStore.shared.resolvedGradient(for: style) {
      collectionView.backgroundColor = .clear
      if let existing = collectionView.backgroundView as? GradientBackgroundView {
        existing.gradient = gradient
      } else {
        collectionView.backgroundView = GradientBackgroundView(gradient: gradient)
      }
    } else {
      collectionView.backgroundView = nil
      collectionView.backgroundColor = .backgroundColor
    }
  }
}
