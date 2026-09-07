/// The JSON error envelope returned by Gmail for a failed request.
public struct GmailErrorResponse: Decodable, Equatable, Sendable {
  /// Error details reported in the response body.
  public let error: ErrorDetails
}

public extension GmailErrorResponse {
  /// The reported error code and any accompanying diagnostics.
  struct ErrorDetails: Decodable, Equatable, Sendable {
    /// The error code reported in the body; the HTTP response supplies its own status.
    public let code: Int

    /// The server's diagnostic message, when included.
    public let message: String?

    /// Individual errors in their received order, when included.
    public let errors: [ErrorEntry]?
  }

  /// One reported reason for a failed request.
  struct ErrorEntry: Decodable, Equatable, Sendable {
    /// The reason string, such as `rateLimitExceeded`. Unknown reasons are preserved.
    public let reason: String

    /// The namespace for this reason, when included.
    public let domain: String?

    /// The server's diagnostic message for this entry, when included.
    public let message: String?

    /// The request field associated with this error, when included.
    public let location: String?

    /// The kind of location, such as `parameter` or `header`, when included.
    public let locationType: String?
  }
}
