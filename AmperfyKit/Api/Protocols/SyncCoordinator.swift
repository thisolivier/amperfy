//  SyncCoordinator.swift
//  AmperfyKit

import Foundation

/// Protocol for managing library sync lifecycle across accounts.
/// Wraps MetaManager creation and access.
@MainActor
public protocol SyncCoordinator {
  func getLibrarySyncer(for accountInfo: AccountInfo) -> LibrarySyncer
  func resetSyncer(for accountInfo: AccountInfo)
  var allActiveAccountInfos: [AccountInfo] { get }
}
