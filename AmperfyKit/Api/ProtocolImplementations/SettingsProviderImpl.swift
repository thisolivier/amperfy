//  SettingsProviderImpl.swift
//  AmperfyKit

import Foundation

/// Thin wrapper around PersistentStorage conforming to SettingsProvider.
/// Reads settings from the underlying PersistentStorage instance.
public class SettingsProviderImpl: SettingsProvider {
  private let storage: PersistentStorage

  public init(storage: PersistentStorage) {
    self.storage = storage
  }

  public var app: AppSettings {
    storage.settings.app
  }

  public var user: UserSettings {
    storage.settings.user
  }

  public var accounts: AccountSettings {
    storage.settings.accounts
  }
}
