//
//  AuditionDeckHomeEntryContent.swift
//  Amperfy
//
//  Discovery-D4: SwiftUI content for the Home widget "Find more" entry
//  points (design doc docs/ux/amperfy-needle-drop-deck-v1-design.md §5.6).
//  Hosted inside a plain `UICollectionViewCell` via `UIHostingConfiguration`
//  — see `AuditionDeckHomeEntryCell.swift`.
//

import SwiftUI

// MARK: - AuditionDeckFindMoreCellContent

/// Section-end trailing cell: "same cell size as siblings... centered
/// sparkle.magnifyingglass icon + 'Find more' label" (design §5.6).
struct AuditionDeckFindMoreCellContent: View {
  let isEnabled: Bool
  let action: () -> ()

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(systemName: "sparkle.magnifyingglass")
          .font(.title2)
        Text("Find more")
          .font(.subheadline)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1.0 : 0.4)
    .accessibilityLabel(
      isEnabled
        ? "Find more, opens recommendations"
        : "Find more, play some music first so we know your taste"
    )
  }
}

// MARK: - AuditionDeckEmptySectionCellContent

/// Empty-section replacement card: `ContentUnavailableView` styled to the
/// widget card, per-section copy, optional action button (design §5.6 /
/// §2 — "Recently added" gets no button, favourite sections do).
struct AuditionDeckEmptySectionCellContent: View {
  let title: String
  let description: String
  let systemImage: String
  let buttonTitle: String?
  let isButtonEnabled: Bool
  let action: (() -> ())?

  var body: some View {
    Group {
      if let buttonTitle, let action {
        ContentUnavailableView {
          Label(title, systemImage: systemImage)
        } description: {
          Text(description)
        } actions: {
          Button(buttonTitle, action: action)
            .disabled(!isButtonEnabled)
            .accessibilityLabel(
              isButtonEnabled
                ? "\(buttonTitle), opens recommendations"
                : "\(buttonTitle), play some music first so we know your taste"
            )
        }
      } else {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
      }
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
  }
}
