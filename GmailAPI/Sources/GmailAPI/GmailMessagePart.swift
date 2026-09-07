/// A MIME part in a Gmail message payload, including any nested child parts.
public struct GmailMessagePart: Decodable, Equatable, Sendable {
  /// The part identifier supplied by Gmail. An empty identifier is preserved.
  public let partId: String?

  /// The part's MIME type, such as `text/plain` or `multipart/alternative`.
  public let mimeType: String?

  /// The attachment filename, when supplied. An empty filename is preserved.
  public let filename: String?

  /// Header entries in their received order, preserving duplicate names and casing.
  public let headers: [Header]?

  /// Inline body content or an attachment reference; may be empty for container parts.
  public let body: GmailMessagePartBody?

  /// Nested MIME parts in their received order, when included.
  public let parts: [GmailMessagePart]?
}

public extension GmailMessagePart {
  /// A name/value entry in this MIME part's header list.
  struct Header: Decodable, Equatable, Sendable {
    /// The header name exactly as returned by Gmail.
    public let name: String

    /// The header value exactly as returned, without decoding or normalization.
    public let value: String
  }
}
