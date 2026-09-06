/// A conversation entry returned by Gmail's `users.threads.list` endpoint.
/// Message contents must be fetched separately with `users.threads.get`.
public struct GmailThreadReference: Decodable, Equatable, Sendable {
  /// The thread identifier within the connected account.
  public let id: String

  /// A short preview of message text, when included in the response.
  public let snippet: String?

  /// The last history record that modified this thread, when included.
  /// This is not the mailbox-wide synchronization checkpoint.
  public let historyId: String?
}
