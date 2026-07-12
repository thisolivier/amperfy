//
//  GigsVC.swift
//  Amperfy
//
//  "Gigs" library tab (spec §1.3): upcoming live shows for the user's library
//  artists, scoped by a user-managed city list or "Near me" (CoreLocation
//  whenInUse, requested lazily on tap). Rows show artist, venue, city,
//  localized date and a source badge; tap opens the ticket URL in Safari;
//  context action shows the artist in the library. Sections are one per week,
//  ascending. Offline: the last successful response per scope is cached and
//  rendered with an "as of" timestamp.
//
//  The gigs-sidecar is not always deployed, so every state degrades gracefully
//  to a clear empty / offline message rather than a spinner or a crash.
//
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
import SafariServices
import UIKit

// MARK: - GigsVC

class GigsVC: UIViewController {
  override var sceneTitle: String? { "Gigs" }

  private let account: Account
  private let settings = GigsSettings.shared
  private let locationProvider = GigsLocationProvider()

  private lazy var service = GigsService(serverUrl: account.serverUrl)

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let asOfLabel = UILabel()
  /// The "as of" banner header, built ONCE (viewDidLoad) and shown/hidden by
  /// swapping tableHeaderView; only asOfLabel.text is toggled thereafter.
  private let asOfHeader = UIView()

  /// The bar button for "Near me" — disabled while a location request is in
  /// flight so a second tap can't overwrite the pending request (QA A4).
  private var nearMeButton: UIBarButtonItem?

  /// Weekly sections currently shown — read by GigsVC+TableView.
  private(set) var weekSections: [GigsWeekSection] = []
  /// The "as of" timestamp when the shown data came from cache; nil when live.
  private var cacheAsOf: Date?
  private var isLoading = false

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setNavBarTitle(title: "Gigs")
    view.backgroundColor = .systemGroupedBackground
    configureTableView()
    configureAsOfBanner()
    configureNavItems()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reload()
  }

  // MARK: - Configuration

  private func configureTableView() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "GigCell")
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  /// Build the offline "as of" banner header ONCE. Thereafter updateAsOfBanner()
  /// only toggles asOfLabel.text and whether the header is attached — it never
  /// rebuilds the view or re-adds constraints (previously a fresh UIView + four
  /// constraints were created on every render).
  private func configureAsOfBanner() {
    asOfLabel.font = .preferredFont(forTextStyle: .caption1)
    asOfLabel.textColor = .secondaryLabel
    asOfLabel.textAlignment = .center
    asOfLabel.numberOfLines = 0
    asOfLabel.translatesAutoresizingMaskIntoConstraints = false
    asOfHeader.addSubview(asOfLabel)
    NSLayoutConstraint.activate([
      asOfLabel.topAnchor.constraint(equalTo: asOfHeader.topAnchor, constant: 8),
      asOfLabel.bottomAnchor.constraint(equalTo: asOfHeader.bottomAnchor, constant: -8),
      asOfLabel.leadingAnchor.constraint(equalTo: asOfHeader.leadingAnchor, constant: 16),
      asOfLabel.trailingAnchor.constraint(equalTo: asOfHeader.trailingAnchor, constant: -16),
    ])
  }

  private func configureNavItems() {
    let addCity = UIBarButtonItem(
      image: UIImage(systemName: "plus"),
      style: .plain,
      target: self,
      action: #selector(promptAddCity)
    )
    let nearMe = UIBarButtonItem(
      image: UIImage(systemName: "location"),
      style: .plain,
      target: self,
      action: #selector(nearMeTapped)
    )
    nearMe.accessibilityLabel = "Find Gigs Near Me"
    nearMeButton = nearMe
    // Manage the followed-city list (view + remove) — QA B-P1-3: the scope was
    // previously add-only, so a typo'd/experimental city stayed forever.
    let manageCities = UIBarButtonItem(
      image: UIImage(systemName: "list.bullet"),
      style: .plain,
      target: self,
      action: #selector(manageCitiesTapped)
    )
    manageCities.accessibilityLabel = "Manage Cities"
    navigationItem.rightBarButtonItems = [addCity, nearMe, manageCities]
  }

  // MARK: - Loading

  private func reload() {
    let cities = settings.cities
    guard !cities.isEmpty else {
      showEmptyState(
        title: "No gigs scope yet",
        message: "Add a city with the + button, or tap the location button to find gigs near you."
      )
      return
    }
    fetch(
      scopes: cities.map { GigScope.city($0) },
      scopeDescription: cities.joined(separator: ", ")
    )
  }

  /// Describes what happened to a single scope's fetch, so the view can surface
  /// a per-scope failure notice when SOME scopes succeed and others fail.
  private struct ScopeOutcome {
    let label: String
    let didSucceedLive: Bool
    /// True when the failure was `.notConfigured` (server has no gigs sidecar)
    /// rather than a transient offline/unreachable error.
    let isNotConfigured: Bool
  }

  /// A short human label for a scope, used in per-scope failure notices.
  private func label(for scope: GigScope) -> String {
    switch scope {
    case let .city(name): return name
    case .near: return "your location"
    }
  }

  /// Fetch several scopes concurrently, merge, group by week. On total failure,
  /// fall back to any cached responses (with an "as of" banner). Per-scope
  /// failures are tracked so a partial failure (some cities refresh, one
  /// doesn't) surfaces an inline "Couldn't refresh: <city>" notice instead of
  /// silently showing a stale subset.
  private func fetch(scopes: [GigScope], scopeDescription: String) {
    guard !isLoading else { return }
    isLoading = true
    setNavBarTitle(title: "Gigs — loading…")

    Task { @MainActor in
      var merged: [GigEvent] = []
      var anySucceeded = false
      var oldestCacheDate: Date?
      var outcomes: [ScopeOutcome] = []

      for scope in scopes {
        do {
          let events = try await service.fetchEvents(scope: scope)
          merged.append(contentsOf: events)
          anySucceeded = true
          outcomes.append(ScopeOutcome(
            label: label(for: scope),
            didSucceedLive: true,
            isNotConfigured: false
          ))
        } catch {
          // Fall back to this scope's cache if present.
          if let cached = service.cachedResponse(for: scope) {
            merged.append(contentsOf: cached.events)
            if oldestCacheDate == nil || cached.storedAt < oldestCacheDate! {
              oldestCacheDate = cached.storedAt
            }
          }
          let isNotConfigured = (error as? GigsServiceError) == .notConfigured
          outcomes.append(ScopeOutcome(
            label: label(for: scope),
            didSucceedLive: false,
            isNotConfigured: isNotConfigured
          ))
        }
      }

      isLoading = false
      setNavBarTitle(title: "Gigs")
      cacheAsOf = anySucceeded ? nil : oldestCacheDate
      weekSections = GigsWeekGrouper.group(events: merged)
      renderCurrentData(
        scopeDescription: scopeDescription,
        hadLiveSuccess: anySucceeded,
        outcomes: outcomes
      )
    }
  }

  private func renderCurrentData(
    scopeDescription: String,
    hadLiveSuccess: Bool,
    outcomes: [ScopeOutcome]
  ) {
    if weekSections.isEmpty {
      if hadLiveSuccess {
        // Explicit zero-events state (QA B-P2-6): the merged-list model
        // otherwise can't distinguish "city added, no events" from "add
        // failed". Name the scope and point at the manage-cities affordance.
        showEmptyState(
          title: "No upcoming gigs",
          message: "Nothing found for \(scopeDescription).\n\nWe'll keep checking — or manage your cities from the list button above."
        )
      } else if outcomes.allSatisfy(\.isNotConfigured), !outcomes.isEmpty {
        // The server simply has no gigs sidecar — a configuration state, not a
        // transient outage. Say so distinctly (A4).
        showEmptyState(
          title: "Gigs isn't set up for this server yet",
          message: "This server doesn't offer the gigs service. Check back later, or ask your server admin to enable it."
        )
      } else {
        showEmptyState(
          title: "Couldn't reach the gigs service",
          message: "Nothing is cached for \(scopeDescription) yet.\n\nCheck back when you're online."
        )
      }
      return
    }
    contentUnavailableConfiguration = nil
    tableView.isHidden = false
    updateAsOfBanner(failedScopes: outcomes.filter { !$0.didSucceedLive }.map(\.label))
    tableView.reloadData()
  }

  /// Show/hide the offline "as of" banner and, when some scopes failed while
  /// others refreshed, an inline "Couldn't refresh: <city>" line. The header
  /// view + its constraints are built once (configureAsOfBanner); here we only
  /// toggle the text and whether the header is attached.
  private func updateAsOfBanner(failedScopes: [String]) {
    var lines: [String] = []
    if let cacheAsOf {
      let formatter = RelativeDateTimeFormatter()
      lines.append(
        "Offline — showing cached gigs as of " +
          formatter.localizedString(for: cacheAsOf, relativeTo: Date())
      )
    }
    if !failedScopes.isEmpty {
      // Only meaningful as a partial-failure notice: at least one scope did
      // refresh (otherwise the empty/offline state already covers it).
      lines.append("Couldn't refresh: \(failedScopes.joined(separator: ", "))")
    }

    guard !lines.isEmpty else {
      tableView.tableHeaderView = nil
      return
    }
    asOfLabel.text = lines.joined(separator: "\n")
    let targetHeight = failedScopes.isEmpty ? 40.0 : 56.0
    asOfHeader.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: targetHeight)
    asOfHeader.layoutIfNeeded()
    tableView.tableHeaderView = asOfHeader
  }

  private func showEmptyState(title: String, message: String) {
    weekSections = []
    tableView.tableHeaderView = nil
    tableView.reloadData()
    tableView.isHidden = true
    var emptyConfig = UIContentUnavailableConfiguration.empty()
    emptyConfig.text = title
    emptyConfig.secondaryText = message
    contentUnavailableConfiguration = emptyConfig
  }

  // MARK: - Scope actions

  @objc
  private func promptAddCity() {
    GigsAddCityPrompt.present(from: self, settings: settings) { [weak self] result in
      guard let self else { return }
      switch result {
      case .added:
        reload()
      case let .alreadyFollowing(city):
        presentBriefNotice("Already following \(city)")
      case .blank:
        break
      }
    }
  }

  /// A brief, dismiss-only notice (used for "Already following <city>"). Kept as
  /// a lightweight alert so it works identically on iPhone / iPad / Mac Catalyst.
  private func presentBriefNotice(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  @objc
  private func manageCitiesTapped() {
    let citiesVC = GigsCitiesVC()
    citiesVC.onChange = { [weak self] in
      self?.reload()
    }
    let nav = UINavigationController(rootViewController: citiesVC)
    citiesVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(dismissPresentedManagement)
    )
    present(nav, animated: true)
  }

  @objc
  private func dismissPresentedManagement() {
    presentedViewController?.dismiss(animated: true)
  }

  @objc
  private func nearMeTapped() {
    // Disable the button for the duration of the request so a second tap can't
    // start (and overwrite) a second in-flight location request (QA A4). The
    // 12s provider timeout guarantees this always re-enables.
    guard nearMeButton?.isEnabled != false else { return }
    nearMeButton?.isEnabled = false
    locationProvider.requestLocation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        self.nearMeButton?.isEnabled = true
        switch result {
        case let .success(coordinate):
          let scope = GigScope.near(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusKm: 50
          )
          self.fetch(scopes: [scope], scopeDescription: "your location")
        case let .failure(error):
          self.presentLocationFailureAlert(error: error)
        }
      }
    }
  }

  private func presentLocationFailureAlert(error: Error) {
    let isDenied = (error as? GigsLocationError) == .denied
    let message = isDenied
      ? "Allow location access in Settings to find gigs near you, or add a city instead."
      : "Couldn't get your location. Try again, or add a city instead."
    let alert = UIAlertController(
      title: "Location Unavailable",
      message: message,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  // MARK: - Navigation from a gig

  /// Open the ticket page IN-APP (SFSafariViewController). Presenting from
  /// GigsVC's own navigation controller (rather than bare `self`) keeps the
  /// dismiss anchored to the Gigs surface: in a collapsed split view, presenting
  /// off `self` could return the user to Home on close (QA B-P1-2). The
  /// long-press "Open in Safari" context action is the external escape hatch.
  func openTicket(for event: GigEvent) {
    guard let url = event.ticketURL else {
      presentBriefNotice("This gig has no ticket link.")
      return
    }
    let safari = SFSafariViewController(url: url)
    safari.modalPresentationStyle = .automatic
    let presenter: UIViewController = navigationController ?? self
    presenter.present(safari, animated: true)
  }

  /// Escape hatch: hand the ticket URL to the system browser.
  func openTicketExternally(for event: GigEvent) {
    guard let url = event.ticketURL else {
      presentBriefNotice("This gig has no ticket link.")
      return
    }
    UIApplication.shared.open(url)
  }

  func showArtistInLibrary(named artistName: String) {
    let matches = appDelegate.storage.main.library.searchArtists(
      for: account,
      searchText: artistName,
      onlyCached: false,
      displayFilter: .all
    )
    if let artist = matches.first(where: {
      $0.name.caseInsensitiveCompare(artistName) == .orderedSame
    }) ?? matches.first {
      let detailVC = AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist)
      navigationController?.pushViewController(detailVC, animated: true)
    } else {
      // Not in the library — hand off to Search prefilled with the name.
      let searchVC = AppStoryboard.Main.segueToSearch(account: account)
      navigationController?.pushViewController(searchVC, animated: true)
    }
  }
}
