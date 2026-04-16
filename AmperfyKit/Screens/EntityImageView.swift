//
//  EntityImageView.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 20.02.22.
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

import Foundation
import UIKit

// MARK: - EntityImageView

open class EntityImageView: UIView {
  // MARK: - PR 17.3 album art border (ThemeStore bridge)

  //
  // AmperfyKit cannot `import Amperfy`, so `EntityImageView` reads the
  // two user-configurable keys directly out of `UserDefaults.standard`
  // using the stringly-typed keys defined in `Amperfy/ThemeStore.swift`.
  // Mirrored here; keep these four constants in sync with the app-side
  // Key enum. If either key goes un-stored, the default behaviour is
  // "no border" (width 0) — matching the designer brief default.
  private enum BorderDefaultsKey {
    static let enabled = "amperfy.fork.theme.enabled"
    static let width = "amperfy.fork.theme.albumArt.borderWidth"
    static let color = "amperfy.fork.theme.albumArt.borderColor"
  }

  /// Notification name mirrored from `ThemeStore.didChangeNotification`.
  /// Subscribed in `init` so every live `EntityImageView` re-applies its
  /// border when the user changes width / color in Settings — no reload
  /// of the hosting cell required.
  private static let themeChangedNotificationName =
    Notification.Name("amperfy.fork.theme.didChange")

  @IBOutlet
  weak var singleImage: LibraryEntityImage!
  @IBOutlet
  weak var quadImage1: LibraryEntityImage!
  @IBOutlet
  weak var quadImage2: LibraryEntityImage!
  @IBOutlet
  weak var quadImage3: LibraryEntityImage!
  @IBOutlet
  weak var quadImage4: LibraryEntityImage!

  private var view: UIView!

  private var quadImages: [LibraryEntityImage] {
    [
      quadImage1,
      quadImage2,
      quadImage3,
      quadImage4,
    ]
  }

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    loadViewFromNib()
    subscribeToThemeChanges()
  }

  override public init(frame: CGRect) {
    super.init(frame: frame)
    loadViewFromNib()
    subscribeToThemeChanges()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func loadViewFromNib() {
    let bundle = Bundle(for: type(of: self))
    let nib = UINib(nibName: String(describing: type(of: self)), bundle: bundle)
    let view = nib.instantiate(withOwner: self, options: nil).first as! UIView
    view.frame = bounds
    view.autoresizingMask = [
      UIView.AutoresizingMask.flexibleWidth,
      UIView.AutoresizingMask.flexibleHeight,
    ]
    addSubview(view)
    self.view = view

    backgroundColor = .clear

    layer.masksToBounds = true
    self.view.backgroundColor = .clear
    self.view.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    quadImages[0].layer.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    quadImages[0].layer.maskedCorners = [.layerMinXMinYCorner]
    quadImages[1].layer.maskedCorners = [.layerMaxXMinYCorner]
    quadImages[2].layer.maskedCorners = [.layerMinXMaxYCorner]
    quadImages[3].layer.maskedCorners = [.layerMaxXMaxYCorner]

    applyArtworkBorder()
  }

  private func subscribeToThemeChanges() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleThemeChanged),
      name: Self.themeChangedNotificationName,
      object: nil
    )
  }

  @objc
  private func handleThemeChanged() {
    applyArtworkBorder()
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // The fallback `.separator` color (and any UIColor set via the
    // settings color well) resolves per-trait; re-stamp the border
    // cgColor so it picks up the new appearance mode.
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      applyArtworkBorder()
    }
  }

  /// PR 17.3: stamp the current ThemeStore border config onto every
  /// layer that already owns this view's corner radius. Called on init,
  /// after every `display(...)` re-layout, on trait changes, and on
  /// `ThemeStore.didChangeNotification`.
  public func applyArtworkBorder() {
    let defaults = UserDefaults.standard
    let isThemeEnabled = defaults.bool(forKey: BorderDefaultsKey.enabled)
    let storedWidth = defaults.double(forKey: BorderDefaultsKey.width)
    let width: CGFloat = isThemeEnabled ? CGFloat(storedWidth) : 0

    let storedColorHex = defaults.string(forKey: BorderDefaultsKey.color)
    let baseColor: UIColor =
      storedColorHex.flatMap { UIColor(borderHex: $0) } ?? UIColor.separator
    let resolvedCGColor = baseColor.resolvedColor(with: traitCollection).cgColor

    let targets: [UIView?] = [singleImage, quadImage1, quadImage2, quadImage3, quadImage4]
    for target in targets {
      guard let target else { continue }
      target.layer.borderWidth = width
      target.layer.borderColor = resolvedCGColor
    }
  }

  public func display(
    theme: ThemePreference,
    container: PlayableContainable,
    cornerRadius: CornerRadius = .small
  ) {
    display(
      theme: theme,
      collection: container.getArtworkCollection(theme: theme),
      cornerRadius: cornerRadius
    )
  }

  public func configureStyling(
    image: UIImage,
    imageSizeType: ArtworkIconSizeType,
    imageTintColor: UIColor,
    backgroundColor: UIColor
  ) {
    singleImage.tintColor = imageTintColor
    view.backgroundColor = backgroundColor
    view.layoutMargins = UIEdgeInsets(
      top: imageSizeType.rawValue,
      left: imageSizeType.rawValue,
      bottom: imageSizeType.rawValue,
      right: imageSizeType.rawValue
    )
    let modImage = image.withRenderingMode(.alwaysTemplate)
    singleImage.display(image: modImage)
  }

  private func display(
    theme: ThemePreference,
    collection: ArtworkCollection,
    cornerRadius: CornerRadius = .small
  ) {
    layer.cornerRadius = cornerRadius.asCGFloat
    quadImages.forEach { $0.isHidden = true }
    singleImage.isHidden = false

    if let quadEntities = collection.quadImageEntity {
      if quadEntities.count > 1 {
        // check if all images are the same
        if Set(quadEntities.compactMap { $0.artwork?.id }).count == 1 {
          singleImage.displayAndUpdate(entity: quadEntities.first!)
        } else {
          singleImage.isHidden = true
          quadImages.forEach {
            $0.display(image: UIImage.getGeneratedArtwork(theme: theme, artworkType: .song))
            $0.isHidden = false
          }
          for (index, entity) in quadEntities.enumerated() {
            guard index < quadImages.count else { break }
            quadImages[index].display(entity: entity)
          }
        }
      } else if let firstEntity = quadEntities.first {
        singleImage.displayAndUpdate(entity: firstEntity)
      } else {
        singleImage.display(artworkType: collection.defaultArtworkType)
      }
    } else if let singleEntity = collection.singleImageEntity {
      singleImage.displayAndUpdate(entity: singleEntity)
    } else {
      singleImage.display(artworkType: collection.defaultArtworkType)
    }
    // PR 17.3: re-stamp border after every display pass — the quad tiles
    // may have been freshly shown/hidden, and cell-reuse means this view
    // could have been handed a stale border config from a previous row.
    applyArtworkBorder()
  }
}

// MARK: - Local hex helper

extension UIColor {
  /// Parses the hex string format ThemeStore writes (e.g. `#FF0000`) into
  /// a UIColor. Duplicated inside AmperfyKit because the app-target
  /// `UIColor(hex:)` convenience lives in `Amperfy/ThemeStore.swift` and
  /// AmperfyKit cannot import the app module. Kept fileprivate so it
  /// does not collide with the app-target convenience in client code.
  fileprivate convenience init?(borderHex: String) {
    let trimmed = borderHex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard trimmed.count == 6, let raw = UInt64(trimmed, radix: 16) else {
      return nil
    }
    self.init(
      red: CGFloat((raw >> 16) & 0xFF) / 255.0,
      green: CGFloat((raw >> 8) & 0xFF) / 255.0,
      blue: CGFloat(raw & 0xFF) / 255.0,
      alpha: 1.0
    )
  }
}
