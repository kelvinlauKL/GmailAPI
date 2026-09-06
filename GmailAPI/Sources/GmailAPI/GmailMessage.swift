/// A Gmail message with its identifiers, metadata, and optional MIME payload.
public struct GmailMessage: Decodable, Equatable, Sendable {
  /// The immutable message identifier within the connected account.
  public let id: String

  /// The identifier of the conversation containing this message.
  public let threadId: String

  /// Labels applied to the message, when included in the response.
  public let labelIds: [String]?

  /// A short preview of the message text, when included.
  public let snippet: String?

  /// The last history record that modified this message, preserved as an opaque string.
  /// This is not the mailbox-wide synchronization checkpoint.
  public let historyId: String?

  /// Gmail's internal timestamp in milliseconds since the Unix epoch, kept as a string.
  /// It determines inbox ordering and can differ from the message's `Date` header.
  public let internalDate: String?

  /// The parsed MIME structure, including headers, body content, and child parts.
  public let payload: GmailMessagePart?

  /// The estimated total message size in bytes, when supplied.
  public let sizeEstimate: Int?

  /// The base64url-encoded RFC 2822 message, when returned by a raw-format request.
  /// The encoded content is preserved without decoding or normalization.
  public let raw: String?
}
