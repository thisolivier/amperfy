//
//  SmartPlaylistBuilderVC.swift
//  Amperfy
//
//  Rule-row query builder for the Smart Playlists feature (V1 spec, 2026-08-17;
//  grouped AND/OR queries per the V1.5 addendum §1).
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

/// The audience-builder-style query form, presented modally inside its own
/// navigation controller.
///
/// # Shape of the form
///
/// The query is a top-level list of items — bare rules and one-level groups —
/// and each item is its own inset card. Between every pair of adjacent items
/// sits an and/or **connector chip**. A level is uniform by construction (pure
/// AND or pure OR; mixing is what groups are for), so every chip at a level
/// shows the same word and tapping any one of them flips the whole level. A
/// group card repeats the pattern inside itself with its own chips, its own
/// "+ Add rule" row and its own ⋯ menu.
///
/// # What it does not do
///
/// The builder edits a COPY of the query and hands it back only when the user
/// taps Run Query — Cancel therefore leaves the stored state, and the frozen
/// result it produced, completely untouched. Nothing here evaluates anything;
/// running the query is the results screen's job (one refresh path, always).
///
/// Every edit goes through the `SmartPlaylistQuery` builder-editing extension,
/// which works on `items`. `SmartPlaylistQuery.rules` is deliberately never
/// assigned anywhere in this screen: its setter flattens the tree and destroys
/// groups.
///
/// A plain `UIViewController` hosting its own table view rather than a
/// `UITableViewController`, because the prominent Run Query bar has to be
/// pinned outside the scrolling area — for a `UITableViewController` the view
/// *is* the table view, so a pinned bar there scrolls with the content.
final class SmartPlaylistBuilderVC: UIViewController {
  private static let ruleCellReuseIdentifier = "SmartPlaylistRuleCell"
  private static let addRuleCellReuseIdentifier = "SmartPlaylistAddRuleCell"
  private static let groupHeaderCellReuseIdentifier = "SmartPlaylistGroupHeaderCell"
  private static let connectorCellReuseIdentifier = "SmartPlaylistConnectorCell"
  private static let actionsCellReuseIdentifier = "SmartPlaylistActionsCell"
  private static let runQueryBarHeight: CGFloat = 76.0

  // MARK: - State

  private let account: Account
  private var editedQuery: SmartPlaylistQuery
  private var rowLayout: SmartPlaylistBuilderRowLayout
  private let onRunQuery: (SmartPlaylistQuery) -> ()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let runQueryBar = UIView()
  private let runQueryButton = UIButton(configuration: .filled())

  // MARK: - Init

  init(
    account: Account,
    initialQuery: SmartPlaylistQuery,
    onRunQuery: @escaping (SmartPlaylistQuery) -> ()
  ) {
    self.account = account
    self.editedQuery = initialQuery
    self.rowLayout = SmartPlaylistBuilderRowLayout(query: initialQuery)
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
    tableView.register(
      SmartPlaylistGroupHeaderCell.self,
      forCellReuseIdentifier: Self.groupHeaderCellReuseIdentifier
    )
    tableView.register(
      SmartPlaylistConnectorChipCell.self,
      forCellReuseIdentifier: Self.connectorCellReuseIdentifier
    )
    tableView.register(
      SmartPlaylistBuilderActionsCell.self,
      forCellReuseIdentifier: Self.actionsCellReuseIdentifier
    )
    tableView.register(
      SmartPlaylistConnectorChipHeaderView.self,
      forHeaderFooterViewReuseIdentifier: SmartPlaylistConnectorChipHeaderView.reuseIdentifier
    )
    tableView.estimatedSectionHeaderHeight = 44
    tableView.estimatedSectionFooterHeight = 24
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
    var queryToRun = editedQuery
    // A group whose rules were all deleted mid-edit says nothing, and an empty
    // OR branch would blank the whole result — drop them before running.
    queryToRun.removeEmptyGroups()
    dismiss(animated: true) { [weak self] in
      self?.onRunQuery(queryToRun)
    }
  }

  // MARK: - Query mutation

  /// The single funnel for every edit. Rebuilding the layout and reloading
  /// wholesale is deliberate: an edit can change the section count, the row
  /// count of two containers and every chip on screen at once, so incremental
  /// updates would be bookkeeping with no user-visible payoff.
  private func mutateQuery(
    scrollToBottomAfterwards: Bool = false,
    _ mutation: (inout SmartPlaylistQuery) -> ()
  ) {
    mutation(&editedQuery)
    rowLayout = SmartPlaylistBuilderRowLayout(query: editedQuery)
    tableView.reloadData()
    if scrollToBottomAfterwards {
      scrollNewestItemIntoView()
    }
  }

  private func scrollNewestItemIntoView() {
    let actionsSectionIndex = rowLayout.actionsSectionIndex
    guard rowLayout.numberOfRows(inSection: actionsSectionIndex) > 0 else { return }
    tableView.scrollToRow(
      at: IndexPath(row: 0, section: actionsSectionIndex),
      at: .bottom,
      animated: true
    )
  }

  // MARK: - Adding rules

  /// Adds a rule to a container: the top level when `groupItemIndex` is `nil`,
  /// otherwise that group.
  fileprivate func addRule(
    ofKind ruleKind: SmartPlaylistRule.Kind,
    toGroupAt groupItemIndex: Int?
  ) {
    guard let newRule = ruleKind.defaultRule else {
      // A membership rule is meaningless without a playlist, so the rule is
      // only appended once one has actually been chosen.
      pushPlaylistPicker { [weak self] playlistChoice in
        guard let self else { return }
        let membershipRule = Self.makeMembershipRule(ofKind: ruleKind, choice: playlistChoice)
        append(rule: membershipRule, toGroupAt: groupItemIndex)
      }
      return
    }
    append(rule: newRule, toGroupAt: groupItemIndex)
  }

  private func append(rule newRule: SmartPlaylistRule, toGroupAt groupItemIndex: Int?) {
    mutateQuery(scrollToBottomAfterwards: true) { query in
      if let groupItemIndex {
        query.appendRule(newRule, toGroupAt: groupItemIndex)
      } else {
        query.appendTopLevelRule(newRule)
      }
    }
  }

  /// Creates a group around its first rule — see
  /// `SmartPlaylistRuleMenuBuilder.makeAddGroupMenu` for why the rule comes
  /// first.
  fileprivate func addGroup(withFirstRuleOfKind ruleKind: SmartPlaylistRule.Kind) {
    guard let firstRule = ruleKind.defaultRule else {
      pushPlaylistPicker { [weak self] playlistChoice in
        guard let self else { return }
        let membershipRule = Self.makeMembershipRule(ofKind: ruleKind, choice: playlistChoice)
        mutateQuery(scrollToBottomAfterwards: true) { $0.appendGroup(withFirstRule: membershipRule)
        }
      }
      return
    }
    mutateQuery(scrollToBottomAfterwards: true) { $0.appendGroup(withFirstRule: firstRule) }
  }

  // MARK: - Editing and deleting

  fileprivate func replaceRule(
    at location: SmartPlaylistBuilderRuleLocation,
    with newRule: SmartPlaylistRule
  ) {
    mutateQuery { $0.replaceRule(at: location, with: newRule) }
  }

  fileprivate func deleteRule(at location: SmartPlaylistBuilderRuleLocation) {
    mutateQuery { $0.removeRule(at: location) }
  }

  /// Removing a group takes its rules with it, so anything beyond a single rule
  /// is confirmed first. A one-rule group is no more costly to lose than the
  /// rule row it holds, which is deleted without ceremony.
  fileprivate func requestDeleteGroup(at itemIndex: Int) {
    guard let group = editedQuery.group(at: itemIndex) else { return }
    guard group.rules.count >= 2 else {
      mutateQuery { $0.removeGroup(at: itemIndex) }
      return
    }
    let alert = UIAlertController(
      title: "Delete Group?",
      message: "This removes the group and all \(group.rules.count) rules inside it.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.mutateQuery { $0.removeGroup(at: itemIndex) }
    })
    present(alert, animated: true)
  }

  fileprivate func setCombinator(
    _ newCombinator: SmartPlaylistCombinator,
    ofGroupAt itemIndex: Int
  ) {
    mutateQuery { $0.setCombinator(newCombinator, ofGroupAt: itemIndex) }
  }

  fileprivate func toggleTopLevelCombinator() {
    mutateQuery { $0.toggleTopLevelCombinator() }
  }

  fileprivate func toggleCombinator(ofGroupAt itemIndex: Int) {
    mutateQuery { $0.toggleCombinator(ofGroupAt: itemIndex) }
  }

  // MARK: - Value pickers

  private static func makeMembershipRule(
    ofKind ruleKind: SmartPlaylistRule.Kind,
    choice: SmartPlaylistPlaylistChoice
  )
    -> SmartPlaylistRule {
    ruleKind == .inPlaylist
      ? .inPlaylist(playlistId: choice.playlistId, name: choice.name)
      : .notInPlaylist(playlistId: choice.playlistId, name: choice.name)
  }

  fileprivate func pushPlaylistPicker(
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
  fileprivate func promptForCustomDayCount(
    at location: SmartPlaylistBuilderRuleLocation,
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
        at: location,
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
    case .completeAlbum, .inPlaylist, .notInPlaylist, .played(.never), .playlistCount:
      return nil
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
    case .completeAlbum, .inPlaylist, .notInPlaylist, .played(.never), .playlistCount:
      return templateRule
    }
  }
}

// MARK: - Cell configuration

extension SmartPlaylistBuilderVC {
  fileprivate func makeRuleCell(
    for tableView: UITableView,
    at indexPath: IndexPath,
    location: SmartPlaylistBuilderRuleLocation,
    contentIndent: CGFloat
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.ruleCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistRuleCell
    guard let rule = editedQuery.rule(at: location) else { return cell }
    let editMenu = SmartPlaylistRuleMenuBuilder.makeEditMenu(
      for: rule,
      onRuleEdited: { [weak self] editedRule in
        self?.replaceRule(at: location, with: editedRule)
      },
      onCustomDayCountRequested: { [weak self] templateRule in
        self?.promptForCustomDayCount(at: location, templateRule: templateRule)
      }
    )
    cell.configureAsRuleRow(
      title: rule.kind.displayName,
      subtitle: rule.displayText,
      menu: editMenu,
      contentIndent: contentIndent,
      // Membership rules have no menu — their value is a playlist, picked in a
      // pushed list.
      tapAction: editMenu == nil ? { [weak self] in
        guard let self else { return }
        pushPlaylistPicker { [weak self] playlistChoice in
          guard let self else { return }
          replaceRule(
            at: location,
            with: Self.makeMembershipRule(ofKind: rule.kind, choice: playlistChoice)
          )
        }
      } : nil
    )
    return cell
  }

  fileprivate func makeAddRuleCell(
    for tableView: UITableView,
    at indexPath: IndexPath,
    groupItemIndex: Int
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.addRuleCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistRuleCell
    cell.configureAsAddRuleRow(
      menu: SmartPlaylistRuleMenuBuilder.makeAddRuleMenu(
        title: "Add Rule to Group",
        addableKinds: editedQuery.addableRuleKinds(forGroupAt: groupItemIndex),
        onAddRuleOfKind: { [weak self] ruleKind in
          self?.addRule(ofKind: ruleKind, toGroupAt: groupItemIndex)
        }
      ),
      contentIndent: SmartPlaylistBuilderStyle.groupContentIndent
    )
    return cell
  }

  fileprivate func makeGroupHeaderCell(
    for tableView: UITableView,
    at indexPath: IndexPath,
    groupItemIndex: Int
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.groupHeaderCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistGroupHeaderCell
    let combinator = editedQuery.group(at: groupItemIndex)?.combinator ?? .all
    cell.configure(
      combinator: combinator,
      optionsMenu: SmartPlaylistRuleMenuBuilder.makeGroupOptionsMenu(
        combinator: combinator,
        onCombinatorChosen: { [weak self] newCombinator in
          self?.setCombinator(newCombinator, ofGroupAt: groupItemIndex)
        },
        onDeleteGroupRequested: { [weak self] in
          self?.requestDeleteGroup(at: groupItemIndex)
        }
      )
    )
    return cell
  }

  fileprivate func makeGroupConnectorCell(
    for tableView: UITableView,
    at indexPath: IndexPath,
    groupItemIndex: Int
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.connectorCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistConnectorChipCell
    cell.configure(
      combinator: editedQuery.group(at: groupItemIndex)?.combinator ?? .all,
      onToggle: { [weak self] in
        self?.toggleCombinator(ofGroupAt: groupItemIndex)
      }
    )
    return cell
  }

  fileprivate func makeActionsCell(
    for tableView: UITableView,
    at indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: Self.actionsCellReuseIdentifier,
      for: indexPath
    ) as! SmartPlaylistBuilderActionsCell
    cell.configure(
      addRuleMenu: SmartPlaylistRuleMenuBuilder.makeAddRuleMenu(
        title: "Add Rule",
        addableKinds: editedQuery.addableRuleKinds(forGroupAt: nil),
        onAddRuleOfKind: { [weak self] ruleKind in
          self?.addRule(ofKind: ruleKind, toGroupAt: nil)
        }
      ),
      addGroupMenu: SmartPlaylistRuleMenuBuilder.makeAddGroupMenu(
        onAddFirstRuleOfKind: { [weak self] ruleKind in
          self?.addGroup(withFirstRuleOfKind: ruleKind)
        }
      )
    )
    return cell
  }
}

// MARK: UITableViewDataSource

extension SmartPlaylistBuilderVC: UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int {
    rowLayout.numberOfSections
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rowLayout.numberOfRows(inSection: section)
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    // The connector chips carry the combinator now, so the title stays neutral
    // — "Match ALL of the following" would contradict an OR level.
    rowLayout.header(forSection: section) == .title ? "Match songs where" : nil
  }

  func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard section == rowLayout.actionsSectionIndex else { return nil }
    return editedQuery.isEmpty
      ? "With no rules the query matches every song in your library."
      : editedQuery.summaryText
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let row = rowLayout.row(at: indexPath) else { return UITableViewCell() }
    let cell: UITableViewCell
    switch row {
    case .actions:
      cell = makeActionsCell(for: tableView, at: indexPath)
    case let .groupAddRule(itemIndex):
      cell = makeAddRuleCell(for: tableView, at: indexPath, groupItemIndex: itemIndex)
    case let .groupConnector(itemIndex, _):
      cell = makeGroupConnectorCell(for: tableView, at: indexPath, groupItemIndex: itemIndex)
    case let .groupHeader(itemIndex):
      cell = makeGroupHeaderCell(for: tableView, at: indexPath, groupItemIndex: itemIndex)
    case let .groupRule(itemIndex, ruleIndex):
      cell = makeRuleCell(
        for: tableView,
        at: indexPath,
        location: .group(itemIndex: itemIndex, ruleIndex: ruleIndex),
        contentIndent: SmartPlaylistBuilderStyle.groupContentIndent
      )
    case let .topLevelRule(itemIndex):
      cell = makeRuleCell(
        for: tableView,
        at: indexPath,
        location: .topLevel(itemIndex: itemIndex),
        contentIndent: 0
      )
    }
    SmartPlaylistBuilderStyle.applyCardBackground(
      to: cell,
      isInsideGroupCard: row.isInsideGroupCard
    )
    return cell
  }
}

// MARK: UITableViewDelegate

extension SmartPlaylistBuilderVC: UITableViewDelegate {
  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard rowLayout.header(forSection: section) == .connector else { return nil }
    let headerView = tableView.dequeueReusableHeaderFooterView(
      withIdentifier: SmartPlaylistConnectorChipHeaderView.reuseIdentifier
    ) as! SmartPlaylistConnectorChipHeaderView
    headerView.configure(combinator: editedQuery.combinator) { [weak self] in
      self?.toggleTopLevelCombinator()
    }
    return headerView
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    // The spacing header still needs a gap, or the trailing actions card butts
    // straight up against the last rule card.
    rowLayout.header(forSection: section) == .spacing
      ? 20
      : UITableView.automaticDimension
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    // Only the trailing section carries text (the live query summary); the rest
    // rely on the next section's header for their spacing.
    section == rowLayout.actionsSectionIndex
      ? UITableView.automaticDimension
      : .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    guard let row = rowLayout.row(at: indexPath) else { return false }
    switch row {
    case .actions, .groupAddRule, .groupConnector: return false
    case .groupHeader, .groupRule, .topLevelRule: return true
    }
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    guard let row = rowLayout.row(at: indexPath) else { return nil }
    // Swiping the group's header row removes the whole group; swiping a rule
    // row removes just that rule, inside a group card exactly as outside one.
    if case let .groupHeader(itemIndex) = row {
      let deleteGroupAction = UIContextualAction(
        style: .destructive,
        title: "Delete Group"
      ) { [weak self] _, _, completionHandler in
        self?.requestDeleteGroup(at: itemIndex)
        completionHandler(true)
      }
      return UISwipeActionsConfiguration(actions: [deleteGroupAction])
    }
    guard let location = row.ruleLocation else { return nil }
    let deleteAction = UIContextualAction(
      style: .destructive,
      title: "Delete"
    ) { [weak self] _, _, completionHandler in
      self?.deleteRule(at: location)
      completionHandler(true)
    }
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }
}
