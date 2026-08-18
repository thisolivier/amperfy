//
//  SmartPlaylistBuilderVC.swift
//  Amperfy
//
//  Rule-row query builder for the Smart Playlists feature (V1 spec, 2026-08-17).
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

// MARK: - SmartPlaylistBuilderVC

/// The Apple-Music-style "Match ALL of the following" rule form, presented
/// modally inside its own navigation controller.
///
/// The builder edits a COPY of the query and hands it back only when the user
/// taps Run Query — Cancel therefore leaves the stored state, and the frozen
/// result it produced, completely untouched. Nothing here evaluates anything;
/// running the query is the results screen's job (one refresh path, always).
///
/// A plain `UIViewController` hosting its own table view rather than a
/// `UITableViewController`, because the prominent Run Query bar has to be
/// pinned outside the scrolling area — for a `UITableViewController` the view
/// *is* the table view, so a pinned bar there scrolls with the content.
final class SmartPlaylistBuilderVC: UIViewController {
  private static let ruleCellReuseIdentifier = "SmartPlaylistRuleCell"
  private static let addRuleCellReuseIdentifier = "SmartPlaylistAddRuleCell"
  private static let runQueryBarHeight: CGFloat = 76.0

  // MARK: - State

  private let account: Account
  private var editedQuery: SmartPlaylistQuery
  private let onRunQuery: (SmartPlaylistQuery) -> ()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let runQueryBar = UIView()
  private let runQueryButton = UIButton(configuration: .filled())

  /// `true` while a rule row is showing the "+ Add rule" affordance, i.e. at
  /// least one rule kind is still addable.
  private var canAddAnyRule: Bool {
    SmartPlaylistRule.Kind.allCases.contains { editedQuery.canAddRule(ofKind: $0) }
  }

  private var addRuleRowIndex: Int? {
    canAddAnyRule ? editedQuery.rules.count : nil
  }

  // MARK: - Init

  init(
    account: Account,
    initialQuery: SmartPlaylistQuery,
    onRunQuery: @escaping (SmartPlaylistQuery) -> ()
  ) {
    self.account = account
    self.editedQuery = initialQuery
    self.onRunQuery = onRunQuery
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Smart Playlist"
    view.backgroundColor = .systemGroupedBackground

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel,
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
    )

    setupTableView()
    setupRunQueryBar()
  }

  private func setupTableView() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(
      SmartPlaylistRuleCell.self,
      forCellReuseIdentifier: Self.ruleCellReuseIdentifier
    )
    tableView.register(
      SmartPlaylistRuleCell.self,
      forCellReuseIdentifier: Self.addRuleCellReuseIdentifier
    )
    tableView.contentInset.bottom = Self.runQueryBarHeight
    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupRunQueryBar() {
    runQueryBar.translatesAutoresizingMaskIntoConstraints = false
    runQueryBar.backgroundColor = .systemGroupedBackground
    view.addSubview(runQueryBar)

    let separatorView = UIView()
    separatorView.translatesAutoresizingMaskIntoConstraints = false
    separatorView.backgroundColor = .separator
    runQueryBar.addSubview(separatorView)

    var runQueryConfiguration = UIButton.Configuration.filled()
    runQueryConfiguration.title = "Run Query"
    runQueryConfiguration.image = UIImage(systemName: "play.circle")
    runQueryConfiguration.imagePadding = 8
    runQueryConfiguration.cornerStyle = .medium
    runQueryConfiguration.buttonSize = .large
    runQueryButton.configuration = runQueryConfiguration
    runQueryButton.translatesAutoresizingMaskIntoConstraints = false
    runQueryButton.addTarget(self, action: #selector(handleRunQueryTapped), for: .touchUpInside)
    runQueryBar.addSubview(runQueryButton)

    NSLayoutConstraint.activate([
      runQueryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      runQueryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      runQueryBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      runQueryBar.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -Self.runQueryBarHeight
      ),

      separatorView.topAnchor.constraint(equalTo: runQueryBar.topAnchor),
      separatorView.leadingAnchor.constraint(equalTo: runQueryBar.leadingAnchor),
      separatorView.trailingAnchor.constraint(equalTo: runQueryBar.trailingAnchor),
      separatorView.heightAnchor.constraint(equalToConstant: 0.5),

      runQueryButton.topAnchor.constraint(equalTo: runQueryBar.topAnchor, constant: 12),
      runQueryButton.leadingAnchor.constraint(equalTo: runQueryBar.leadingAnchor, constant: 20),
      runQueryButton.trailingAnchor.constraint(equalTo: runQueryBar.trailingAnchor, constant: -20),
    ])
  }

  // MARK: - Actions

  @objc
  private func handleRunQueryTapped() {
    let queryToRun = editedQuery
    dismiss(animated: true) { [weak self] in
      self?.onRunQuery(queryToRun)
    }
  }

  private func reloadRules() {
    tableView.reloadData()
  }

  // MARK: - Rule mutation

  private func addRule(ofKind ruleKind: SmartPlaylistRule.Kind) {
    switch ruleKind {
    case .addedWithinDays:
      editedQuery.rules.append(.addedWithinDays(30))
      reloadRules()
    case .played:
      editedQuery.rules.append(.played(.never))
      reloadRules()
    case .playlistCount:
      editedQuery.rules.append(.playlistCount(comparison: .fewerThan, count: 1))
      reloadRules()
    case .inPlaylist, .notInPlaylist:
      // A membership rule is meaningless without a playlist, so the rule is
      // only appended once one has actually been chosen.
      pushPlaylistPicker { [weak self] playlistChoice in
        guard let self else { return }
        editedQuery.rules.append(makeMembershipRule(ofKind: ruleKind, choice: playlistChoice))
        reloadRules()
      }
    }
  }

  private func replaceRule(at ruleIndex: Int, with newRule: SmartPlaylistRule) {
    guard editedQuery.rules.indices.contains(ruleIndex) else { return }
    editedQuery.rules[ruleIndex] = newRule
    reloadRules()
  }

  private func deleteRule(at ruleIndex: Int) {
    guard editedQuery.rules.indices.contains(ruleIndex) else { return }
    editedQuery.rules.remove(at: ruleIndex)
    reloadRules()
  }

  private func makeMembershipRule(
    ofKind ruleKind: SmartPlaylistRule.Kind,
    choice: SmartPlaylistPlaylistChoice
  )
    -> SmartPlaylistRule {
    ruleKind == .inPlaylist
      ? .inPlaylist(playlistId: choice.playlistId, name: choice.name)
      : .notInPlaylist(playlistId: choice.playlistId, name: choice.name)
  }

  private func pushPlaylistPicker(
    onPlaylistChosen: @escaping (SmartPlaylistPlaylistChoice) -> ()
  ) {
    let pickerVC = SmartPlaylistPlaylistPickerVC(
      account: account,
      onPlaylistChosen: onPlaylistChosen
    )
    navigationController?.pushViewController(pickerVC, animated: true)
  }

  /// The one place a rule value is typed rather than picked, for day counts
  /// outside the preset ladder.
  private func promptForCustomDayCount(
    ruleIndex: Int,
    templateRule: SmartPlaylistRule
  ) {
    let alert = UIAlertController(
      title: "Number of Days",
      message: "Enter how many days the rule should cover.",
      preferredStyle: .alert
    )
    alert.addTextField { textField in
      textField.keyboardType = .numberPad
      textField.placeholder = "30"
      textField.text = String(Self.dayCount(of: templateRule) ?? 30)
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
      guard let self,
            let enteredText = alert?.textFields?.first?.text,
            let enteredDays = Int(enteredText),
            enteredDays > 0
      else { return }
      replaceRule(
        at: ruleIndex,
        with: Self.rule(templateRule, withDayCount: enteredDays)
      )
    })
    present(alert, animated: true)
  }

  private static func dayCount(of rule: SmartPlaylistRule) -> Int? {
    switch rule {
    case let .addedWithinDays(days): return days
    case let .played(.notInLastDays(days)): return days
    case let .played(.inLastDays(days)): return days
    case .inPlaylist, .notInPlaylist, .played(.never), .playlistCount: return nil
    }
  }

  private static func rule(
    _ templateRule: SmartPlaylistRule,
    withDayCount days: Int
  )
    -> SmartPlaylistRule {
    switch templateRule {
    case .addedWithinDays: return .addedWithinDays(days)
    case .played(.notInLastDays): return .played(.notInLastDays(days))
    case .played(.inLastDays): return .played(.inLastDays(days))
    case .inPlaylist, .notInPlaylist, .played(.never), .playlistCount: return templateRule
    }
  }
}

// MARK: UITableViewDataSource

extension SmartPlaylistBuilderVC: UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int { 1 }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    editedQuery.rules.count + (canAddAnyRule ? 1 : 0)
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    "Match ALL of the following"
  }

  func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    editedQuery.rules.isEmpty
      ? "With no rules the query matches every song in your library."
      : editedQuery.summaryText
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.row == addRuleRowIndex {
      let cell = tableView.dequeueReusableCell(
        withIdentifier: Self.addRuleCellReuseIdentifier,
        for: indexPath
      ) as! SmartPlaylistRuleCell
      cell.configureAsAddRuleRow(
        menu: SmartPlaylistRuleMenuBuilder.makeAddRuleMenu(
          for: editedQuery,
          onAddRuleOfKind: { [weak self] ruleKind in self?.addRule(ofKind: ruleKind) }
        )
      )
      return cell
    }

    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.ruleCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistRuleCell
    let ruleIndex = indexPath.row
    let rule = editedQuery.rules[ruleIndex]
    let editMenu = SmartPlaylistRuleMenuBuilder.makeEditMenu(
      for: rule,
      onRuleEdited: { [weak self] editedRule in
        self?.replaceRule(at: ruleIndex, with: editedRule)
      },
      onCustomDayCountRequested: { [weak self] templateRule in
        self?.promptForCustomDayCount(ruleIndex: ruleIndex, templateRule: templateRule)
      }
    )
    cell.configureAsRuleRow(
      title: rule.kind.displayName,
      subtitle: rule.displayText,
      menu: editMenu,
      // Membership rules have no menu — their value is a playlist, picked in a
      // pushed list.
      tapAction: editMenu == nil ? { [weak self] in
        guard let self else { return }
        pushPlaylistPicker { [weak self] playlistChoice in
          guard let self else { return }
          replaceRule(
            at: ruleIndex,
            with: makeMembershipRule(ofKind: rule.kind, choice: playlistChoice)
          )
        }
      } : nil
    )
    return cell
  }
}

// MARK: UITableViewDelegate

extension SmartPlaylistBuilderVC: UITableViewDelegate {
  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    indexPath.row != addRuleRowIndex
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    guard indexPath.row != addRuleRowIndex else { return nil }
    let deleteAction = UIContextualAction(
      style: .destructive,
      title: "Delete"
    ) { [weak self] _, _, completionHandler in
      self?.deleteRule(at: indexPath.row)
      completionHandler(true)
    }
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }
}

// MARK: - SmartPlaylistRuleCell

/// A rule row rendered as one full-width button so the whole row opens its
/// value menu — the same feel as a pop-up-button form row, and it keeps the
/// cell's swipe-to-delete intact.
private final class SmartPlaylistRuleCell: UITableViewCell {
  private let rowButton = UIButton(configuration: .plain())
  private var tapAction: (() -> ())?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    rowButton.translatesAutoresizingMaskIntoConstraints = false
    rowButton.contentHorizontalAlignment = .leading
    rowButton.addTarget(self, action: #selector(handleRowButtonTapped), for: .touchUpInside)
    contentView.addSubview(rowButton)
    NSLayoutConstraint.activate([
      rowButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      rowButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      rowButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      rowButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configureAsRuleRow(
    title: String,
    subtitle: String,
    menu: UIMenu?,
    tapAction: (() -> ())?
  ) {
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.title = title
    buttonConfiguration.subtitle = subtitle
    buttonConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = .preferredFont(forTextStyle: .footnote)
      attributes.foregroundColor = UIColor.secondaryLabel
      return attributes
    }
    buttonConfiguration.subtitleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.font = .preferredFont(forTextStyle: .body)
        attributes.foregroundColor = UIColor.label
        return attributes
      }
    buttonConfiguration.image = UIImage(systemName: "chevron.up.chevron.down")
    buttonConfiguration.imagePlacement = .trailing
    buttonConfiguration.imagePadding = 8
    rowButton.configuration = buttonConfiguration
    rowButton.menu = menu
    rowButton.showsMenuAsPrimaryAction = (menu != nil)
    self.tapAction = tapAction
  }

  func configureAsAddRuleRow(menu: UIMenu) {
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.title = "Add Rule"
    buttonConfiguration.image = UIImage(systemName: "plus.circle.fill")
    buttonConfiguration.imagePadding = 8
    rowButton.configuration = buttonConfiguration
    rowButton.menu = menu
    rowButton.showsMenuAsPrimaryAction = true
    tapAction = nil
  }

  @objc
  private func handleRowButtonTapped() {
    tapAction?()
  }
}
