//  DownloadCoordinator.swift
//  AmperfyKit

import Foundation

/// Protocol for managing download managers across accounts.
/// Wraps MetaManager download access.
@MainActor
public protocol DownloadCoordinator {
  func getPlayableDownloader(for accountInfo: AccountInfo) -> DownloadManageable
  func getArtworkDownloader(for accountInfo: AccountInfo) -> DownloadManageable
}
