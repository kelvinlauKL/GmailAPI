import Foundation

/// An unsuccessful Gmail HTTP response and its available diagnostics.
public struct GmailRequestFailure: LocalizedError, Equatable, Sendable {
  /// The actual HTTP status, which takes precedence over a code in the JSON body.
  public let statusCode: Int

  /// Structured diagnostics decoded from the response body, when available.
  public let details: GmailErrorResponse.ErrorDetails?

  /// The `Retry-After` header as received, when provided.
  public let retryAfter: String?

  public init(
    statusCode: Int,
    details: GmailErrorResponse.ErrorDetails? = nil,
    retryAfter: String? = nil
  ) {
    self.statusCode = statusCode
    self.details = details
    self.retryAfter = retryAfter
  }

  public var errorDescription: String? {
    "The Gmail request failed with HTTP status \(statusCode)."
  }

  public var failureReason: String? {
    "Gmail did not return the expected successful HTTP status."
  }

  public var recoverySuggestion: String? {
    "Check the HTTP status, account permissions, quota, and service availability before retrying."
  }
}
