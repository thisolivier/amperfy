//  LibraryProvider.swift
//  AmperfyKit

import Foundation

/// Protocol for read-only library data queries.
/// Wraps LibraryStorage to provide a clean API boundary.
public protocol LibraryProvider {
  // Songs
  func getSongs(for account: Account) -> [Song]
  func getSong(for account: Account, id: String) -> Song?
  func getCachedSongs(for account: Account) -> [Song]
  func getFavoriteSongs(for account: Account) -> [Song]
  func getRandomSongs(for account: Account, count: Int, onlyCached: Bool) -> [Song]

  // Albums
  func getAlbums(for account: Account) -> [Album]
  func getAlbum(for account: Account, id: String) -> Album?
  func getFavoriteAlbums(for account: Account) -> [Album]
  func getNewestAlbums(for account: Account, offset: Int, count: Int) -> [Album]
  func getRecentAlbums(for account: Account, offset: Int, count: Int) -> [Album]

  // Artists
  func getArtists(for account: Account) -> [Artist]
  func getArtist(for account: Account, id: String) -> Artist?
  func getFavoriteArtists(for account: Account) -> [Artist]

  // Playlists
  func getPlaylists(for account: Account, areSystemPlaylistsIncluded: Bool) -> [Playlist]
  func getPlaylist(for account: Account, id: String) -> Playlist?

  // Genres
  func getGenres(for account: Account) -> [Genre]
  func getGenre(for account: Account, id: String) -> Genre?

  // Search
  func searchArtists(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: ArtistCategoryFilter
  ) -> [Artist]
  func searchAlbums(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: DisplayCategoryFilter
  ) -> [Album]
  func searchSongs(
    for account: Account,
    searchText: String,
    onlyCached: Bool,
    displayFilter: DisplayCategoryFilter
  ) -> [Song]
  func searchPlaylists(
    for account: Account,
    searchText: String,
    playlistSearchCategory: PlaylistSearchCategory
  ) -> [Playlist]

  // Counts
  func getSongCount(for account: Account) -> Int
  func getAlbumCount(for account: Account) -> Int
  func getArtistCount(for account: Account) -> Int
  func getPlaylistCount(for account: Account) -> Int
  func getCachedSongCount(for account: Account) -> Int

  // Player data
  func getPlayerData() -> PlayerData

  // Accounts
  func getAccount(info: AccountInfo) -> Account
  func getAllAccounts() -> [Account]
}
