import SwiftUI

// MARK: - AuditionDeckEndCardView

/// Final page of the deck: session summary + Deal more / Done. Deck v2: no audition tracking —
/// the summary is "You liked <m>" only (user-settled 2026-07-03). Done pops the deck page.
struct AuditionDeckEndCardView: View {
  let likedCount: Int
  let dealMoreLabel: String
  let onDealMore: () -> ()
  let onDone: () -> ()

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "checkmark.rectangle.stack")
        .font(.system(size: 56))
        .foregroundStyle(.secondary)

      Text("That's the deck")
        .font(.title2.bold())

      Text("You liked \(likedCount)")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VStack(spacing: 12) {
        Button(dealMoreLabel, action: onDealMore)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)

        Button("Done", action: onDone)
          .buttonStyle(.bordered)
          .controlSize(.large)
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}
