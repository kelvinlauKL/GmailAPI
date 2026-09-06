/// The body of a MIME message part, also returned by `messages.attachments.get`.
public struct GmailMessagePartBody: Decodable, Equatable, Sendable {
  /// An opaque identifier for content retrieved with a separate attachment request.
  /// A missing identifier indicates that content is supplied in `data`, when present.
  public let attachmentId: String?

  /// The number of body bytes before base64url encoding, when supplied.
  /// A missing size is unknown, not necessarily zero.
  public let size: Int?

  /// The base64url-encoded content, preserved exactly as Gmail returned it.
  /// This may be absent or empty for container parts or separately fetched attachments.
  /// Decode to bytes before interpreting text using the part's declared character set.
  public let data: String?
}
