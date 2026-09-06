/// The mailbox profile returned by Gmail's `users.getProfile` endpoint.
public struct GmailProfile: Decodable, Equatable, Sendable {
  /// The account's email address.
  public let emailAddress: String

  /// The total number of messages in the mailbox.
  public let messagesTotal: Int

  /// The total number of conversations in the mailbox.
  public let threadsTotal: Int

  /// The current mailbox history cursor, preserved as an opaque string.
  public let historyID: String

  public init(
    emailAddress: String,
    messagesTotal: Int,
    threadsTotal: Int,
    historyID: String
  ) {
    self.emailAddress = emailAddress
    self.messagesTotal = messagesTotal
    self.threadsTotal = threadsTotal
    self.historyID = historyID
  }

  private enum CodingKeys: String, CodingKey {
    case emailAddress
    case messagesTotal
    case threadsTotal
    case historyID = "historyId"
  }
}
