/// A conversation fetched from Gmail's `users.threads.get` endpoint.
/// Requires the message collection; use `GmailThreadReference` for listing entries.
public struct GmailThread: Decodable, Equatable, Sendable {
  /// The thread identifier within the connected account.
  public let id: String

  /// A short preview of message text, when included in the response.
  public let snippet: String?

  /// The last history record that modified this thread, preserved as an opaque string.
  /// This is not the mailbox-wide synchronization checkpoint.
  public let historyId: String?

  /// Messages in the order returned by Gmail, without sorting or normalization.
  /// An explicit empty array is preserved; an omitted or null collection fails decoding.
  public let messages: [GmailMessage]
}
