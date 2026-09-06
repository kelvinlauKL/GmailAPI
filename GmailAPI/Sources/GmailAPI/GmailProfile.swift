/// The mailbox profile returned by Gmail's `users.getProfile` endpoint.
public struct GmailProfile: Decodable, Equatable, Sendable {
  /// The account's email address.
  public let emailAddress: String

  /// The total number of messages across the entire mailbox at fetch time.
  /// This is not limited to the app's search results or imported messages.
  public let messagesTotal: Int

  /// The total number of conversations across the entire mailbox at fetch time.
  /// A conversation can contain multiple messages.
  public let threadsTotal: Int

  /// The current mailbox history cursor, preserved as an opaque string.
  public let historyID: String

  private enum CodingKeys: String, CodingKey {
    case emailAddress
    case messagesTotal
    case threadsTotal
    case historyID = "historyId"
  }
}
