/// One page returned by Gmail's `users.history.list` endpoint.
public struct GmailHistoryListResponse: Decodable, Equatable, Sendable {
  /// Change records in their returned order. Gmail may omit this field when empty.
  public let history: [GmailHistoryRecord]?

  /// Pass this token to the next history request. Its absence marks the last page.
  public let nextPageToken: String?

  /// The mailbox's current history ID, preserved as an opaque string.
  /// Save it for the next sync only after processing every page of changes.
  public let historyId: String
}
