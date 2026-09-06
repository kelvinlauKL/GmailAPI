import Foundation

/// Connects Gmail requests to the host application's account credentials.
/// The host owns credential storage, token expiry, and coordinated refresh.
public struct GmailTokenProvider: Sendable {
  private let retrieveAccessToken: @Sendable () async throws -> String
  private let invalidateRejectedAccessToken: @Sendable (String) async throws -> Void

  /// Supply a current token without the `Bearer` prefix.
  /// The invalidation handler must discard the cached access token only if it
  /// still matches the rejected token. Preserve any newer replacement and the
  /// refresh credentials needed to obtain another access token.
  public init(
    retrieveAccessToken: @escaping @Sendable () async throws -> String,
    invalidateRejectedAccessToken: @escaping @Sendable (String) async throws -> Void
  ) {
    self.retrieveAccessToken = retrieveAccessToken
    self.invalidateRejectedAccessToken = invalidateRejectedAccessToken
  }

  /// Asks the host for a token on every call; this adapter does not cache tokens.
  public func accessToken() async throws -> String {
    try Task.checkCancellation()
    let accessToken = try await retrieveAccessToken()
    guard !accessToken.isEmpty,
      accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw TokenError.invalidAccessToken
    }
    return accessToken
  }

  /// Reports the exact token rejected by Gmail, without replacing it or retrying.
  public func invalidate(rejectedAccessToken: String) async throws {
    try Task.checkCancellation()
    try await invalidateRejectedAccessToken(rejectedAccessToken)
  }

  public enum TokenError: LocalizedError, Equatable {
    case invalidAccessToken

    public var errorDescription: String? {
      "The credential provider returned an invalid access token."
    }

    public var failureReason: String? {
      "The access token was empty or contained whitespace."
    }

    public var recoverySuggestion: String? {
      "Provide a current access token without whitespace or the Bearer prefix."
    }
  }
}
