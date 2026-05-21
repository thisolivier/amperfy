//  SettingsProvider.swift
//  AmperfyKit

import Foundation

/// Protocol for read-only access to app settings.
/// Wraps AmperfySettings to provide a clean API boundary.
public protocol SettingsProvider {
  var app: AppSettings { get }
  var user: UserSettings { get }
  var accounts: AccountSettings { get }
}
