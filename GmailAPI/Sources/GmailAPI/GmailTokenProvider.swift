/// Connects Gmail requests to the host application's account credentials.
/// The host owns credential storage, token expiry, and coordinated refresh.
public protocol GmailTokenProvider: Sendable {
  /// Returns a current, nonempty access token without whitespace or the `Bearer` prefix.
  /// Refresh expired credentials as needed, coordinating concurrent refresh requests.
  func accessToken() async throws -> String

  /// Invalidates the cached access token only if it still matches the token Gmail rejected.
  /// Preserve any newer replacement and the refresh credentials needed to obtain
  /// another access token. This operation must not revoke the account's authorization.
  func invalidate(rejectedAccessToken: String) async throws
}
