import SwiftUI

// MARK: - NeedleDropBar

/// Per-collection audition scrubber: dragging it plays ~1.5s pre-rendered slices of each track
/// from a single server-prepared preview sprite audio file. See
/// `docs/ux/amperfy-needle-drop-deck-v1-design.md` §5.3 for the full anatomy/gesture spec this
/// view implements. This is a standalone control — it owns no knowledge of any surrounding deck
/// or card (out of scope for this sprint).
public struct NeedleDropBar: View {
  @StateObject
  private var controller: NeedleDropBarController
  @State
  private var isDragging = false
  private let autoAuditionTrigger: Bool

  /// Normal path: a sprite manifest is already in hand (Ready state).
  public init(
    manifest: NeedleDropManifest,
    spritePlayer: NeedleDropSpritePlayer? = nil,
    autoAuditionTrigger: Bool = false
  ) {
    self.init(
      availability: .ready(manifest),
      spritePlayer: spritePlayer,
      autoAuditionTrigger: autoAuditionTrigger
    )
  }

  /// Lets a caller render the LoadingSprite/Unavailable states correctly even though no fetch
  /// pipeline exists yet in this sprint. `autoAuditionTrigger`: flip false -> true to fire the
  /// Ready -> AutoAuditioning transition (D4's "card settles" hook; nothing drives this
  /// automatically here).
  public init(
    availability: NeedleDropSpriteAvailability,
    spritePlayer: NeedleDropSpritePlayer? = nil,
    autoAuditionTrigger: Bool = false
  ) {
    _controller = StateObject(wrappedValue: NeedleDropBarController(
      availability: availability,
      spritePlayer: spritePlayer
    ))
    self.autoAuditionTrigger = autoAuditionTrigger
  }

  public var body: some View {
    Group {
      switch controller.state {
      case .loadingSprite:
        loadingSkeleton
      case .unavailable:
        unavailableLabel
      default:
        interactiveBar
      }
    }
    .onChange(of: autoAuditionTrigger) { _, newValue in
      if newValue { controller.startAutoAuditioning() }
    }
    .onDisappear { controller.stop() }
  }

  // MARK: States without gesture interaction

  private var loadingSkeleton: some View {
    Capsule()
      .fill(Color.white.opacity(0.15))
      .frame(height: 10)
      .frame(maxWidth: .infinity)
      .modifier(ShimmerEffect())
      .frame(height: 44)
      .allowsHitTesting(false)
  }

  private var unavailableLabel: some View {
    Label("Preview unavailable", systemImage: "speaker.slash")
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(height: 44)
  }

  // MARK: Ready/active states

  private var interactiveBar: some View {
    GeometryReader { geometry in
      let barWidth = geometry.size.width
      ZStack(alignment: .topLeading) {
        segmentTrack(barWidth: barWidth)
        if isAuditioning {
          needle(barWidth: barWidth)
        }
        callout(x: controller.scrubX, barWidth: barWidth)
      }
      .contentShape(Rectangle())
      .gesture(dragGesture(barWidth: barWidth))
    }
    .frame(height: 44)
  }

  private var isAuditioning: Bool {
    [
      NeedleDropBarAuditionState.scrubbing,
      .riding,
      .pausedAudition,
      .autoAuditioning,
    ].contains(controller.state)
  }

  private func segmentTrack(barWidth: CGFloat) -> some View {
    let slices = controller.slices
    let gap: CGFloat = slices.count > 1 ? 1.5 : 0
    let totalGap = gap * CGFloat(max(slices.count - 1, 0))
    let segmentWidth = slices.isEmpty ? 0 : (barWidth - totalGap) / CGFloat(slices.count)

    return HStack(spacing: gap) {
      ForEach(Array(slices.enumerated()), id: \.element.id) { index, _ in
        Capsule()
          .fill(
            index == controller.currentSliceIndex && isAuditioning ? Color.white : Color.white
              .opacity(0.35)
          )
          .frame(width: max(segmentWidth, 0), height: 10)
      }
    }
    .frame(width: barWidth, height: 44, alignment: .center)
  }

  private func needle(barWidth: CGFloat) -> some View {
    VStack(spacing: 0) {
      Circle().fill(Color.white).frame(width: 6, height: 6)
      Rectangle().fill(Color.white).frame(width: 2, height: 18)
    }
    .position(x: needleX(barWidth: barWidth), y: 22)
  }

  private func needleX(barWidth: CGFloat) -> CGFloat {
    if controller.state == .scrubbing, let scrubX = controller.scrubX {
      return min(max(scrubX, 0), barWidth)
    }
    let slices = controller.slices
    guard !slices.isEmpty else { return 0 }
    let gap: CGFloat = slices.count > 1 ? 1.5 : 0
    let segmentWidth = (barWidth - gap * CGFloat(max(slices.count - 1, 0))) / CGFloat(slices.count)
    let index = CGFloat(min(max(controller.currentSliceIndex, 0), slices.count - 1))
    return index * (segmentWidth + gap) + segmentWidth / 2
  }

  @ViewBuilder
  private func callout(x: CGFloat?, barWidth: CGFloat) -> some View {
    let slices = controller.slices
    if controller.state == .scrubbing, let x,
       slices.indices.contains(controller.currentSliceIndex) {
      let slice = slices[controller.currentSliceIndex]
      let maxWidth = barWidth * 0.7
      let clampedX = min(max(x, maxWidth / 2), barWidth - maxWidth / 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(slice.title).font(.caption2.bold()).lineLimit(1)
        Text(slice.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: maxWidth, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      .position(x: clampedX, y: -20)
    }
  }

  // MARK: Gesture

  private func dragGesture(barWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let isFirstEvent = !isDragging
        isDragging = true
        controller.handleDragChanged(
          x: value.location.x,
          barWidth: barWidth,
          isFirstEvent: isFirstEvent
        )
      }
      .onEnded { value in
        isDragging = false
        let distance = hypot(value.translation.width, value.translation.height)
        controller.handleDragEnded(
          translationDistance: distance,
          x: value.location.x,
          barWidth: barWidth
        )
      }
  }
}

// MARK: - ShimmerEffect

/// Minimal non-interactive shimmer used by the LoadingSprite state's skeleton capsule.
private struct ShimmerEffect: ViewModifier {
  @State
  private var isAnimating = false

  func body(content: Content) -> some View {
    content
      .opacity(isAnimating ? 0.3 : 1.0)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          isAnimating = true
        }
      }
  }
}
