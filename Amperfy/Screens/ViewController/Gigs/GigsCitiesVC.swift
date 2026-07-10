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
  private let emptyStateLabel = UILabel()

  /// Called after any add/remove so the presenting Gigs list can reload.
  var onChange: (() -> ())?

  private var cities: [String] { settings.cities }

  override func viewDidLoad() {
    super.viewDidLoad()
    setNavBarTitle(title: "Cities")
    view.backgroundColor = .systemGroupedBackground
    configureTableView()
    configureEmptyState()
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

  private func configureEmptyState() {
    emptyStateLabel.numberOfLines = 0
    emptyStateLabel.textAlignment = .center
    emptyStateLabel.textColor = .secondaryLabel
    emptyStateLabel.font = .preferredFont(forTextStyle: .body)
    emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyStateLabel.text = "No cities yet.\n\nTap + to follow a city's upcoming gigs."
    emptyStateLabel.isHidden = true
    view.addSubview(emptyStateLabel)
    NSLayoutConstraint.activate([
      emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyStateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
      emptyStateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
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
    emptyStateLabel.isHidden = !isEmpty
    tableView.isHidden = isEmpty
    editButtonItem.isEnabled = !isEmpty
    if isEmpty, isEditing { setEditing(false, animated: true) }
  }

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
      tableView.reloadData()
      refreshEmptyState()
      onChange?()
    })
    present(alert, animated: true)
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
