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
  private let emptyStateLabel = UILabel()
  private let asOfLabel = UILabel()

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
    configureEmptyState()
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

  private func configureEmptyState() {
    emptyStateLabel.numberOfLines = 0
    emptyStateLabel.textAlignment = .center
    emptyStateLabel.textColor = .secondaryLabel
    emptyStateLabel.font = .preferredFont(forTextStyle: .body)
    emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyStateLabel.isHidden = true
    view.addSubview(emptyStateLabel)
    NSLayoutConstraint.activate([
      emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyStateLabel.leadingAnchor.constraint(
        equalTo: view.leadingAnchor, constant: 40
      ),
      emptyStateLabel.trailingAnchor.constraint(
        equalTo: view.trailingAnchor, constant: -40
      ),
    ])
  }

  private func configureAsOfBanner() {
    asOfLabel.font = .preferredFont(forTextStyle: .caption1)
    asOfLabel.textColor = .secondaryLabel
    asOfLabel.textAlignment = .center
    asOfLabel.numberOfLines = 0
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
        "No gigs scope yet.\n\nAdd a city with the + button, or tap the location button to find gigs near you."
      )
      return
    }
    fetch(
      scopes: cities.map { GigScope.city($0) },
      scopeDescription: cities.joined(separator: ", ")
    )
  }

  /// Fetch several scopes concurrently, merge, group by week. On total failure,
  /// fall back to any cached responses (with an "as of" banner).
  private func fetch(scopes: [GigScope], scopeDescription: String) {
    guard !isLoading else { return }
    isLoading = true
    setNavBarTitle(title: "Gigs — loading…")

    Task { @MainActor in
      var merged: [GigEvent] = []
      var anySucceeded = false
      var oldestCacheDate: Date?

      for scope in scopes {
        do {
          let events = try await service.fetchEvents(scope: scope)
          merged.append(contentsOf: events)
          anySucceeded = true
        } catch {
          // Fall back to this scope's cache if present.
          if let cached = service.cachedResponse(for: scope) {
            merged.append(contentsOf: cached.events)
            if oldestCacheDate == nil || cached.storedAt < oldestCacheDate! {
              oldestCacheDate = cached.storedAt
            }
          }
        }
      }

      isLoading = false
      setNavBarTitle(title: "Gigs")
      cacheAsOf = anySucceeded ? nil : oldestCacheDate
      weekSections = GigsWeekGrouper.group(events: merged)
      renderCurrentData(scopeDescription: scopeDescription, hadLiveSuccess: anySucceeded)
    }
  }

  private func renderCurrentData(scopeDescription: String, hadLiveSuccess: Bool) {
    if weekSections.isEmpty {
      if hadLiveSuccess {
        // Explicit zero-events state (QA B-P2-6): the merged-list model
        // otherwise can't distinguish "city added, no events" from "add
        // failed". Name the scope and point at the manage-cities affordance.
        showEmptyState(
          "No upcoming gigs for \(scopeDescription).\n\nWe'll keep checking — or manage your cities from the list button above."
        )
      } else {
        showEmptyState(
          "Couldn't reach the gigs service, and nothing is cached for \(scopeDescription) yet.\n\nCheck back when you're online."
        )
      }
      return
    }
    emptyStateLabel.isHidden = true
    tableView.isHidden = false
    updateAsOfBanner()
    tableView.reloadData()
  }

  private func updateAsOfBanner() {
    guard let cacheAsOf else {
      tableView.tableHeaderView = nil
      return
    }
    let formatter = RelativeDateTimeFormatter()
    asOfLabel.text = "Offline — showing cached gigs as of " +
      formatter.localizedString(for: cacheAsOf, relativeTo: Date())
    let header = UIView()
    asOfLabel.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(asOfLabel)
    NSLayoutConstraint.activate([
      asOfLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
      asOfLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
      asOfLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      asOfLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
    ])
    header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 40)
    header.layoutIfNeeded()
    tableView.tableHeaderView = header
  }

  private func showEmptyState(_ message: String) {
    weekSections = []
    tableView.tableHeaderView = nil
    tableView.reloadData()
    tableView.isHidden = true
    emptyStateLabel.text = message
    emptyStateLabel.isHidden = false
  }

  // MARK: - Scope actions

  @objc
  private func promptAddCity() {
    let alert = UIAlertController(
      title: "Add City",
      message: "Show upcoming gigs in this city.",
      preferredStyle: .alert
    )
    alert.addTextField { $0.placeholder = "e.g. London" }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
      guard let self, let text = alert.textFields?.first?.text else { return }
      settings.addCity(text)
      reload()
    })
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
    locationProvider.requestLocation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case let .success(coordinate):
          let scope = GigScope.near(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusKm: 50
          )
          self.fetch(scopes: [scope], scopeDescription: "your location")
        case .failure:
          self.presentLocationDeniedAlert()
        }
      }
    }
  }

  private func presentLocationDeniedAlert() {
    let alert = UIAlertController(
      title: "Location Unavailable",
      message: "Allow location access in Settings to find gigs near you, or add a city instead.",
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
    guard let url = event.ticketURL else { return }
    let safari = SFSafariViewController(url: url)
    safari.modalPresentationStyle = .automatic
    let presenter: UIViewController = navigationController ?? self
    presenter.present(safari, animated: true)
  }

  /// Escape hatch: hand the ticket URL to the system browser.
  func openTicketExternally(for event: GigEvent) {
    guard let url = event.ticketURL else { return }
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
