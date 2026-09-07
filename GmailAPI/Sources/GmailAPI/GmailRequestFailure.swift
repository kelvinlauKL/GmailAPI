import Foundation

/// An unsuccessful Gmail HTTP response and its available diagnostics.
public struct GmailRequestFailure: LocalizedError, Equatable, Sendable {
  /// The actual HTTP status, which takes precedence over a code in the JSON body.
  public let statusCode: Int

  /// Structured diagnostics decoded from the response body, when available.
  public let details: GmailErrorResponse.ErrorDetails?

  /// The `Retry-After` header as received, when provided.
  public let retryAfter: String?

  /// The request context used to interpret a missing resource response.
  public let context: Context

  public init(
    statusCode: Int,
    details: GmailErrorResponse.ErrorDetails? = nil,
    retryAfter: String? = nil,
    context: Context = .general
  ) {
    self.statusCode = statusCode
    self.details = details
    self.retryAfter = retryAfter
    self.context = context
  }

  /// Classifies the HTTP status using Gmail's reported reasons and request context.
  public var category: Category {
    switch statusCode {
    case Constant.badRequestStatusCode: .badRequest
    case Constant.unauthorizedStatusCode: .unauthorized
    case Constant.forbiddenStatusCode: forbiddenCategory()
    case Constant.notFoundStatusCode: context == .historyList ? .historyExpired : .notFound
    case Constant.rateLimitedStatusCode: .rateLimited
    case Constant.serverErrorStatusCodes: .serverError
    default: .other
    }
  }

  /// Whether a temporary failure may succeed on retry.
  /// The caller must still bound attempts and honor any `Retry-After` delay.
  public var isRetryable: Bool {
    switch category {
    case .rateLimited: true
    case .serverError: Constant.retryableServerStatusCodes.contains(statusCode)
    default: false
    }
  }

  public var errorDescription: String? {
    "The Gmail request failed with HTTP status \(statusCode)."
  }

  public var failureReason: String? {
    switch category {
    case .badRequest: "Gmail rejected the request parameters."
    case .unauthorized: "Gmail rejected the credentials."
    case .forbidden: "Gmail denied the request without a recognized temporary rate-limit reason."
    case .quotaExceeded: "The project's daily Gmail quota has been exceeded."
    case .rateLimited: "Gmail is limiting the volume of requests."
    case .notFound: "The requested Gmail resource was not found."
    case .historyExpired: "The starting history ID is invalid or expired."
    case .serverError: "Gmail reported a server error."
    case .other: "Gmail did not return the expected successful HTTP status."
    }
  }

  public var recoverySuggestion: String? {
    switch category {
    case .badRequest: "Check the request parameters before retrying."
    case .unauthorized: "Refresh the credentials or sign in again before retrying."
    case .forbidden: "Check account permissions, granted scopes, and domain policies before retrying."
    case .quotaExceeded: "Check the project's daily quota and wait for it to reset or adjust it before retrying."
    case .rateLimited: "Reduce request volume and retry with backoff, honoring Retry-After when supplied."
    case .notFound: "Verify that the resource still exists and is accessible."
    case .historyExpired: "Perform a full mailbox sync before requesting incremental changes again."
    case .serverError:
      isRetryable
        ? "Retry with bounded backoff, honoring Retry-After when supplied."
        : "Check service availability and the supported operation before retrying."
    case .other: "Check the HTTP status and request details before retrying."
    }
  }

  private func forbiddenCategory() -> Category {
    guard let errors = details?.errors, !errors.isEmpty else { return .forbidden }
    let reasons = errors.map(\.reason)
    if reasons.allSatisfy(Constant.rateLimitReasons.contains) {
      return .rateLimited
    }
    if reasons.contains(Constant.dailyLimitReason), reasons.allSatisfy({ reason in
      reason == Constant.dailyLimitReason || Constant.rateLimitReasons.contains(reason)
    }) {
      return .quotaExceeded
    }
    return .forbidden
  }
}

public extension GmailRequestFailure {
  enum Context: Equatable, Sendable {
    case general
    case historyList
  }

  enum Category: Equatable, Sendable {
    case badRequest
    case unauthorized
    case forbidden
    case quotaExceeded
    case rateLimited
    case notFound
    case historyExpired
    case serverError
    case other
  }
}

private extension GmailRequestFailure {
  enum Constant {
    static let badRequestStatusCode: Int = 400
    static let unauthorizedStatusCode: Int = 401
    static let forbiddenStatusCode: Int = 403
    static let notFoundStatusCode: Int = 404
    static let rateLimitedStatusCode: Int = 429
    static let serverErrorStatusCodes: ClosedRange<Int> = 500...599
    static let retryableServerStatusCodes: Set<Int> = [500, 502, 503, 504]
    static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded"]
    static let dailyLimitReason: String = "dailyLimitExceeded"
  }
}
