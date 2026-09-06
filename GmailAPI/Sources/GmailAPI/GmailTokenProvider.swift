/// Supplies access tokens for one Google account.
/// Implementations manage token expiry and coordinated refresh. The host owns
/// interactive sign-in and persistent credential storage.
public protocol GmailTokenProvider: Sendable {
  /// Returns a current, nonempty access token without whitespace or the `Bearer` prefix.
  /// Refresh expired credentials as needed, coordinating concurrent refresh requests.
  func accessToken() async throws -> String

  /// Invalidates the cached access token only if it still matches the token Gmail rejected.
  /// Preserve any newer replacement and the refresh credentials needed to obtain
  /// another access token. This operation must not revoke the account's authorization.
  func invalidate(rejectedAccessToken: String) async throws
}
