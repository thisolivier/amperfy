//  LibraryProviderImpl.swift
//  AmperfyKit

import Foundation

/// Thin wrapper around LibraryStorage conforming to LibraryProvider.
public class LibraryProviderImpl: LibraryProvider {
  private let libraryStorage: LibraryStorage

  public init(libraryStorage: LibraryStorage) {
    self.libraryStorage = libraryStorage
  }

  // MARK: - Songs

  public func getSongs(for account: Account) -> [Song] {
    libraryStorage.getSongs(for: account)
  }

  public func getSong(for account: Account, id: String) -> Song? {
    libraryStorage.getSong(for: account, id: id)
  }

  public func getCachedSongs(for account: Account) -> [Song] {
    libraryStorage.getCachedSongs(for: account)
  }

  public func getFavoriteSongs(for account: Account) -> [Song] {
    libraryStorage.getFavoriteSongs(for: account)
  }

  public func getRandomSongs(for account: Account, count: Int, onlyCached: Bool) -> [Song] {
    libraryStorage.getRandomSongs(for: account, count: count, onlyCached: onlyCached)
  }

  // MARK: - Albums

  public func getAlbums(for account: Account) -> [Album] {
    libraryStorage.getAlbums(for: account)
  }

  public func getAlbum(for account: Account, id: String) -> Album? {
    libraryStorage.getAlbum(for: account, id: id, isDetailFaultResolution: false)
  }

  public func getFavoriteAlbums(for account: Account) -> [Album] {
    libraryStorage.getFavoriteAlbums(for: account)
  }

  public func getNewestAlbums(for account: Account, offset: Int, count: Int) -> [Album] {
    libraryStorage.getNewestAlbums(for: account, offset: offset, count: count)
  }

  public func getRecentAlbums(for account: Account, offset: Int, count: Int) -> [Album] {
    libraryStorage.getRecentAlbums(for: account, offset: offset, count: count)
  }

  // MARK: - Artists

  public func getArtists(for account: Account) -> [Artist] {
    libraryStorage.getArtists(for: account)
  }

  public func getArtist(for account: Account, id: String) -> Artist? {
    libraryStorage.getArtist(for: account, id: id)
  }

  public func getFavoriteArtists(for account: Account) -> [Artist] {
    libraryStorage.getFavoriteArtists(for: account)
  }

  // MARK: - Playlists

  public func getPlaylists(for account: Account, areSystemPlaylistsIncluded: Bool) -> [Playlist] {
    libraryStorage.getPlaylists(
      for: account,
      areSystemPlaylistsIncluded: areSystemPlaylistsIncluded
    )
  }

  public func getPlaylist(for account: Account, id: String) -> Playlist? {
    libraryStorage.getPlaylist(for: account, id: id)
  }

  // MARK: - Genres

  public func getGenres(for account: Account) -> [Genre] {
    libraryStorage.getGenres(for: account)
  }

  public func getGenre(for account: Account, id: String) -> Genre? {
    libraryStorage.getGenre(for: account, id: id)
  }

  // MARK: - Search

  public func searchArtists(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: ArtistCategoryFilter
  )
    -> [Artist] {
    libraryStorage.searchArtists(
      for: account,
      searchText: searchText,
      onlyCached: onlyCached,
      displayFilter: displayFilter
    )
  }

  public func searchAlbums(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: DisplayCategoryFilter
  )
    -> [Album] {
    libraryStorage.searchAlbums(
      for: account,
      searchText: searchText,
      onlyCached: onlyCached,
      displayFilter: displayFilter
    )
  }

  public func searchSongs(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: DisplayCategoryFilter
  )
    -> [Song] {
    libraryStorage.searchSongs(
      for: account,
      searchText: searchText,
      onlyCached: onlyCached,
      displayFilter: displayFilter
    )
  }

  public func searchPlaylists(
    for account: Account,
    searchText: String,
    playlistSearchCategory: PlaylistSearchCategory
  )
    -> [Playlist] {
    libraryStorage.searchPlaylists(
      for: account,
      searchText: searchText,
      playlistSearchCategory: playlistSearchCategory
    )
  }

  // MARK: - Counts

  public func getSongCount(for account: Account) -> Int {
    libraryStorage.getSongCount(for: account)
  }

  public func getAlbumCount(for account: Account) -> Int {
    libraryStorage.getAlbumCount(for: account)
  }

  public func getArtistCount(for account: Account) -> Int {
    libraryStorage.getArtistCount(for: account)
  }

  public func getPlaylistCount(for account: Account) -> Int {
    libraryStorage.getPlaylistCount(for: account)
  }

  public func getCachedSongCount(for account: Account) -> Int {
    libraryStorage.getCachedSongCount(for: account)
  }

  // MARK: - Player & Accounts

  public func getPlayerData() -> PlayerData {
    libraryStorage.getPlayerData()
  }

  public func getAccount(info: AccountInfo) -> Account {
    libraryStorage.getAccount(info: info)
  }

  public func getAllAccounts() -> [Account] {
    libraryStorage.getAllAccounts()
  }
}
