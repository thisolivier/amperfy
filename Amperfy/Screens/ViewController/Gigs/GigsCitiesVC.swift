//
//  GigsCitiesVC.swift
//  Amperfy
//
//  Manage the Gigs city scope (spec §1.3 + QA B-P1-3): list the cities the user
//  follows, add new ones, and remove them (swipe-delete or Edit mode). The Gigs
//  list itself was previously add-only, so a typo'd or experimental city stayed
//  in the fetch set forever and invisibly. This screen is the single place that
//  shows AND edits the active city list, persisted via GigsSettings.
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
import UIKit

// MARK: - GigsCitiesVC

/// A small table of the followed cities with add / swipe-delete / Edit-mode
/// removal. Changes persist immediately via `GigsSettings`; `onChange` lets the
/// hosting Gigs list re-fetch when the sheet is dismissed.
class GigsCitiesVC: UIViewController {
  override var sceneTitle: String? { "Cities" }

  private let settings = GigsSettings.shared
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)

  /// Called after any add/remove so the presenting Gigs list can reload.
  var onChange: (() -> ())?

  private var cities: [String] { settings.cities }

  override func viewDidLoad() {
    super.viewDidLoad()
    setNavBarTitle(title: "Cities")
    view.backgroundColor = .systemGroupedBackground
    configureTableView()
    configureNavItems()
    refreshEmptyState()
  }

  private func configureTableView() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CityCell")
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func configureNavItems() {
    let addCity = UIBarButtonItem(
      barButtonSystemItem: .add,
      target: self,
      action: #selector(promptAddCity)
    )
    navigationItem.rightBarButtonItems = [addCity, editButtonItem]
  }

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    tableView.setEditing(editing, animated: animated)
  }

  private func refreshEmptyState() {
    let isEmpty = cities.isEmpty
    tableView.isHidden = isEmpty
    editButtonItem.isEnabled = !isEmpty
    if isEmpty, isEditing { setEditing(false, animated: true) }
    if isEmpty {
      var emptyConfig = UIContentUnavailableConfiguration.empty()
      emptyConfig.text = "No cities yet"
      emptyConfig.secondaryText = "Tap + to follow a city's upcoming gigs."
      contentUnavailableConfiguration = emptyConfig
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  @objc
  private func promptAddCity() {
    GigsAddCityPrompt.present(from: self, settings: settings) { [weak self] result in
      guard let self else { return }
      switch result {
      case .added:
        tableView.reloadData()
        refreshEmptyState()
        onChange?()
      case let .alreadyFollowing(city):
        let alert = UIAlertController(
          title: nil,
          message: "Already following \(city)",
          preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
      case .blank:
        break
      }
    }
  }

  private func remove(at indexPath: IndexPath) {
    let city = cities[indexPath.row]
    settings.removeCity(city)
    tableView.deleteRows(at: [indexPath], with: .automatic)
    refreshEmptyState()
    onChange?()
  }
}

// MARK: UITableViewDataSource, UITableViewDelegate

extension GigsCitiesVC: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    cities.count
  }

  func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "CityCell", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = cities[indexPath.row]
    content.image = UIImage(systemName: "mappin.and.ellipse")
    cell.contentConfiguration = content
    cell.selectionStyle = .none
    return cell
  }

  func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    remove(at: indexPath)
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    let delete = UIContextualAction(
      style: .destructive,
      title: "Remove"
    ) { [weak self] _, _, done in
      self?.remove(at: indexPath)
      done(true)
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }
}
