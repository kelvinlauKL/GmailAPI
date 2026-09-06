/// One page returned by Gmail's `users.threads.list` endpoint.
public struct GmailThreadListResponse: Decodable, Equatable, Sendable {
  /// Conversation entries on this page. Gmail may omit this field when empty.
  public let threads: [GmailThreadReference]?

  /// Pass this token to the next list request. Its absence marks the last page.
  public let nextPageToken: String?

  /// An estimate of total matching threads across all pages, when provided.
  /// Use `nextPageToken`, not this estimate, to determine whether to continue.
  public let resultSizeEstimate: UInt32?
}
