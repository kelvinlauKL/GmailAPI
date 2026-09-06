/// A mailbox change record returned by Gmail's `users.history.list` endpoint.
/// Its message values typically contain only `id` and `threadId`.
public struct GmailHistoryRecord: Decodable, Equatable, Sendable {
  /// The mailbox sequence ID for this record, preserved as an opaque string.
  public let id: String

  /// Changed messages, which may also appear in the specific change lists below.
  /// Prefer those lists when determining how each message changed.
  public let messages: [GmailMessage]?

  /// Messages added to the mailbox, when included in this record.
  public let messagesAdded: [MessageAdded]?

  /// Messages permanently deleted from the mailbox, when included in this record.
  /// Moving a message to Trash is a label change.
  public let messagesDeleted: [MessageDeleted]?

  /// Labels added to messages, when included in this record.
  public let labelsAdded: [LabelAdded]?

  /// Labels removed from messages, when included in this record.
  public let labelsRemoved: [LabelRemoved]?
}

extension GmailHistoryRecord {
  /// A message addition within this history record.
  public struct MessageAdded: Decodable, Equatable, Sendable {
    /// The message added to the mailbox.
    public let message: GmailMessage
  }

  /// A permanent message deletion within this history record.
  public struct MessageDeleted: Decodable, Equatable, Sendable {
    /// The message deleted from the mailbox.
    public let message: GmailMessage
  }

  /// A label addition within this history record.
  public struct LabelAdded: Decodable, Equatable, Sendable {
    /// The message whose labels changed.
    public let message: GmailMessage

    /// The labels added by this event, separate from `message.labelIds`.
    public let labelIds: [String]
  }

  /// A label removal within this history record.
  public struct LabelRemoved: Decodable, Equatable, Sendable {
    /// The message whose labels changed.
    public let message: GmailMessage

    /// The labels removed by this event, separate from `message.labelIds`.
    public let labelIds: [String]
  }
}
