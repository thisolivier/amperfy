//
//  AuditionDeckHomeEntryCell.swift
//  Amperfy
//
//  Discovery-D4: hosts `AuditionDeckHomeEntryContent`'s SwiftUI views inside
//  a plain `UICollectionViewCell` for `HomeVC`'s diffable data source, via
//  `UIHostingConfiguration` (a standard SwiftUI/UIKit-interop framework
//  API, iOS 16+ — this app's deployment target is 26.0). No other cell in
//  this codebase hosts SwiftUI this way yet (existing SwiftUI-in-UIKit
//  spots use a full `UIHostingController` child-VC, appropriate for a
//  screen, not a leaf list cell) — see report for the rationale.
//

import SwiftUI
import UIKit

final class AuditionDeckHomeEntryCell: UICollectionViewCell {
  static let reuseID = "AuditionDeckHomeEntryCell"

  func configureFindMore(isEnabled: Bool, action: @escaping () -> ()) {
    contentConfiguration = UIHostingConfiguration {
      AuditionDeckFindMoreCellContent(isEnabled: isEnabled, action: action)
    }
    .margins(.all, 0)
  }

  func configureEmptyState(
    title: String,
    description: String,
    systemImage: String,
    buttonTitle: String?,
    isButtonEnabled: Bool,
    action: (() -> ())?
  ) {
    contentConfiguration = UIHostingConfiguration {
      AuditionDeckEmptySectionCellContent(
        title: title,
        description: description,
        systemImage: systemImage,
        buttonTitle: buttonTitle,
        isButtonEnabled: isButtonEnabled,
        action: action
      )
    }
    .margins(.all, 0)
  }
}
