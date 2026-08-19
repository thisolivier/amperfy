//
//  PlayerToast.swift
//  Amperfy
//
//  Transient in-view feedback capsule for the full-screen popup player.
//
//  Why this exists: `AppDelegate`'s shared `eventLogger` banners are
//  suppressed whenever the top view controller has a `presentedViewController`
//  (AppDelegateAlertExtensions.swift), and the popup player *is* a presented
//  `.pageSheet` (MiniPlayerView.swift). So any banner raised while the player
//  is open is silently swallowed — including the "wrong version" flag's
//  success and, worse, its failure message. This view puts the feedback
//  inside the player itself instead of touching that upstream-shared banner
//  behaviour.
//

import UIKit

// MARK: - PlayerToast

/// A small rounded capsule that slides in from the top of a player view,
/// announces one short outcome, and removes itself.
///
/// - Attaches to the popup player VC's own `view`, so it works in *both*
///   display styles (large artwork and compact queue list) — those swap the
///   content views underneath, not the VC's root view.
/// - Never intercepts touches (`isUserInteractionEnabled == false`), so the
///   player controls stay live while it is on screen.
/// - Only one toast is visible at a time; a new one replaces the old.
@MainActor
final class PlayerToast: UIView {
  // MARK: Style

  enum Style {
    case success
    case failure

    var symbolName: String {
      switch self {
      case .success: return "checkmark.circle.fill"
      case .failure: return "exclamationmark.triangle.fill"
      }
    }

    var symbolColor: UIColor {
      switch self {
      case .success: return .systemGreen
      case .failure: return .systemOrange
      }
    }

    /// Failure copy is longer and more consequential, so it lingers.
    var displayDuration: TimeInterval {
      switch self {
      case .success: return 2.5
      case .failure: return 4.0
      }
    }
  }

  // MARK: Layout constants

  private static let horizontalMarginToContainer = 16.0
  private static let topMarginToSafeArea = 8.0
  private static let capsuleHorizontalPadding = 14.0
  private static let capsuleVerticalPadding = 10.0
  private static let slideInOffset = 24.0
  private static let animationDuration = 0.25

  // MARK: Presentation

  /// Shows `message` inside `containerView`, replacing any toast already
  /// there, and schedules its automatic dismissal.
  @discardableResult
  static func show(
    message: String,
    style: Style,
    in containerView: UIView
  )
    -> PlayerToast {
    dismissExistingToasts(in: containerView)

    let toast = PlayerToast(message: message, style: style)
    containerView.addSubview(toast)

    NSLayoutConstraint.activate([
      toast.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
      toast.topAnchor.constraint(
        equalTo: containerView.safeAreaLayoutGuide.topAnchor,
        constant: topMarginToSafeArea
      ),
      toast.leadingAnchor.constraint(
        greaterThanOrEqualTo: containerView.safeAreaLayoutGuide.leadingAnchor,
        constant: horizontalMarginToContainer
      ),
      toast.trailingAnchor.constraint(
        lessThanOrEqualTo: containerView.safeAreaLayoutGuide.trailingAnchor,
        constant: -horizontalMarginToContainer
      ),
    ])

    containerView.layoutIfNeeded()
    toast.alpha = 0
    toast.transform = CGAffineTransform(translationX: 0, y: -slideInOffset)
    UIView.animate(withDuration: animationDuration) {
      toast.alpha = 1
      toast.transform = .identity
    }

    UIAccessibility.post(notification: .announcement, argument: message)

    toast.scheduleAutomaticDismissal(after: style.displayDuration)
    return toast
  }

  private static func dismissExistingToasts(in containerView: UIView) {
    for existingToast in containerView.subviews.compactMap({ $0 as? PlayerToast }) {
      existingToast.dismiss(animated: false)
    }
  }

  // MARK: Lifecycle

  private var dismissalWorkItem: DispatchWorkItem?
  private weak var backgroundView: UIVisualEffectView?

  private init(message: String, style: Style) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // Feedback only — the player's own controls must stay tappable through it.
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    setupSubviews(message: message, style: style)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupSubviews(message: String, style: Style) {
    let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.clipsToBounds = true
    addSubview(backgroundView)

    let symbolImageView = UIImageView(image: UIImage(systemName: style.symbolName))
    symbolImageView.translatesAutoresizingMaskIntoConstraints = false
    symbolImageView.tintColor = style.symbolColor
    symbolImageView.contentMode = .scaleAspectFit
    symbolImageView.setContentHuggingPriority(.required, for: .horizontal)
    symbolImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

    let messageLabel = UILabel()
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.text = message
    messageLabel.font = .preferredFont(forTextStyle: .footnote)
    messageLabel.adjustsFontForContentSizeCategory = true
    messageLabel.textColor = .label
    messageLabel.numberOfLines = 0

    let contentStack = UIStackView(arrangedSubviews: [symbolImageView, messageLabel])
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .horizontal
    contentStack.alignment = .center
    contentStack.spacing = 8
    backgroundView.contentView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

      contentStack.topAnchor.constraint(
        equalTo: backgroundView.contentView.topAnchor,
        constant: Self.capsuleVerticalPadding
      ),
      contentStack.bottomAnchor.constraint(
        equalTo: backgroundView.contentView.bottomAnchor,
        constant: -Self.capsuleVerticalPadding
      ),
      contentStack.leadingAnchor.constraint(
        equalTo: backgroundView.contentView.leadingAnchor,
        constant: Self.capsuleHorizontalPadding
      ),
      contentStack.trailingAnchor.constraint(
        equalTo: backgroundView.contentView.trailingAnchor,
        constant: -Self.capsuleHorizontalPadding
      ),
    ])

    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.2
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 2)

    self.backgroundView = backgroundView
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Capsule while the text fits on one line, softly rounded once it wraps.
    let cornerRadius = min(bounds.height / 2, 20)
    backgroundView?.layer.cornerCurve = .continuous
    backgroundView?.layer.cornerRadius = cornerRadius
  }

  // MARK: Dismissal

  private func scheduleAutomaticDismissal(after delay: TimeInterval) {
    let workItem = DispatchWorkItem { [weak self] in
      self?.dismiss(animated: true)
    }
    dismissalWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func dismiss(animated: Bool) {
    dismissalWorkItem?.cancel()
    dismissalWorkItem = nil

    guard animated else {
      removeFromSuperview()
      return
    }
    UIView.animate(
      withDuration: Self.animationDuration,
      animations: {
        self.alpha = 0
        self.transform = CGAffineTransform(translationX: 0, y: -Self.slideInOffset)
      },
      completion: { _ in
        self.removeFromSuperview()
      }
    )
  }
}
