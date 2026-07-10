//
//  GigsVC+TableView.swift
//  Amperfy
//
//  UITableView data source / delegate for the Gigs view: one section per week,
//  a row per event (artist · venue · city · localized date · source badge),
//  tap → ticket URL in Safari, context menu → show artist in library.
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

extension GigsVC: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int {
    weekSections.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    weekSections[section].events.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    Self.weekHeaderFormatter.string(from: weekSections[section].weekStart).uppercased()
  }

  func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "GigCell", for: indexPath)
    let event = weekSections[indexPath.section].events[indexPath.row]

    var content = cell.defaultContentConfiguration()
    content.text = event.artistName
    let dateText = Self.rowDateFormatter.string(from: event.startsAt)
    content
      .secondaryText =
      "\(event.venueName) · \(event.city)\n\(dateText) · \(event.source.capitalized)"
    content.secondaryTextProperties.numberOfLines = 2
    content.secondaryTextProperties.color = .secondaryLabel
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let event = weekSections[indexPath.section].events[indexPath.row]
    openTicket(for: event)
  }

  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    let event = weekSections[indexPath.section].events[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let showArtist = UIAction(
        title: "Show Artist in Library",
        image: UIImage(systemName: "person.crop.circle")
      ) { _ in
        self?.showArtistInLibrary(named: event.artistName)
      }
      let openTicket = UIAction(
        title: "Open Ticket Page",
        image: UIImage(systemName: "ticket")
      ) { _ in
        self?.openTicket(for: event)
      }
      return UIMenu(children: [showArtist, openTicket])
    }
  }

  private static let weekHeaderFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "'Week of' MMM d"
    return formatter
  }()

  private static let rowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}
