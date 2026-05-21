//  SyncCoordinatorImpl.swift
//  AmperfyKit

import Foundation

/// Thin wrapper around AmperKit's MetaManager lifecycle conforming to SyncCoordinator.
/// Delegates to AmperKit.shared for MetaManager creation and access.
public class SyncCoordinatorImpl: SyncCoordinator {
  private let amperKit: AmperKit

  public init(amperKit: AmperKit) {
    self.amperKit = amperKit
  }

  public func getLibrarySyncer(for accountInfo: AccountInfo) -> LibrarySyncer {
    amperKit.getMeta(accountInfo).librarySyncer
  }

  public func resetSyncer(for accountInfo: AccountInfo) {
    amperKit.resetMeta(accountInfo)
  }

  public var allActiveAccountInfos: [AccountInfo] {
    Array(amperKit.allActiveMetas.keys)
  }
}
