//  DownloadCoordinatorImpl.swift
//  AmperfyKit

import Foundation

/// Thin wrapper around AmperKit's MetaManager download access conforming to DownloadCoordinator.
@MainActor
public class DownloadCoordinatorImpl: DownloadCoordinator {
  private let amperKit: AmperKit

  public init(amperKit: AmperKit) {
    self.amperKit = amperKit
  }

  public func getPlayableDownloader(for accountInfo: AccountInfo) -> DownloadManageable {
    amperKit.getMeta(accountInfo).playableDownloadManager
  }

  public func getArtworkDownloader(for accountInfo: AccountInfo) -> DownloadManageable {
    amperKit.getMeta(accountInfo).artworkDownloadManager
  }
}
