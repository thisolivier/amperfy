import SwiftUI

// MARK: - AuditionDeckCardActionsView

/// Primary action + more menu (design §5.2). All playback/navigation intents are surfaced as
/// closures — this view has no knowledge of `AuditionDeckController` or UIKit navigation, both of
/// which are the caller's (`AuditionDeckCardView`'s) concern.
struct AuditionDeckCardActionsView: View {
  /// Title of the currently-auditioned track, if any — drives both the primary button's dynamic
  /// label and whether "Play from start" appears in the menu (design §5.2).
  let auditionedTrackTitle: String?
  let onPlay: () -> ()
  let onPlayFromStart: () -> ()
  let onShuffle: () -> ()
  let onAddToQueue: () -> ()
  let onOpen: () -> ()

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onPlay) {
        Label(
          DeckCandidateFormatting.primaryActionLabel(auditionedTrackTitle: auditionedTrackTitle),
          systemImage: "play.fill"
        )
        .lineLimit(1)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)

      Menu {
        if auditionedTrackTitle != nil {
          Button("Play from start", systemImage: "play", action: onPlayFromStart)
        }
        Button("Shuffle", systemImage: "shuffle", action: onShuffle)
        Button("Add to Queue", systemImage: "tray.and.arrow.down", action: onAddToQueue)
        Button("Open", systemImage: "arrow.up.forward.square", action: onOpen)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel("More actions")
    }
  }
}
