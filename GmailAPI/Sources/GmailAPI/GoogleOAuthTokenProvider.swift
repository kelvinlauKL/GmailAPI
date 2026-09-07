import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Refreshes and caches access tokens for one Google account in memory.
/// The host supplies credentials from secure storage after interactive sign-in.
/// Share one instance per account to coordinate refreshes; create a new instance
/// after signing in again. This provider supports refresh tokens without DPoP binding.
public actor GoogleOAuthTokenProvider: GmailTokenProvider {
  private let clientID: String
  private let clientSecret: String?
  private let refreshToken: String
  private let transport: any GmailTransport
  private var cachedToken: CachedToken?
  private var refreshTask: Task<String, Error>?

  public init(
    clientID: String,
    clientSecret: String? = nil,
    refreshToken: String,
    transport: any GmailTransport = URLSessionGmailTransport()
  ) throws {
    guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProviderError.missingCredentials
    }
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.refreshToken = refreshToken
    self.transport = transport
  }

  /// Reuses a cached token until it approaches expiry, otherwise shares one refresh.
  /// Cancelling a caller does not cancel the refresh needed by other callers.
  /// A caller cancelled while waiting receives cancellation after the refresh finishes.
  public func accessToken() async throws -> String {
    try Task.checkCancellation()
    if let cachedToken,
      cachedToken.expiresAt.timeIntervalSinceNow > Constant.refreshLeeway
    {
      return cachedToken.value
    }
    let pendingRefresh: Task<String, Error>
    if let refreshTask {
      pendingRefresh = refreshTask
    } else {
      pendingRefresh = Task { try await self.refreshAccessToken() }
      refreshTask = pendingRefresh
    }
    let result = await pendingRefresh.result
    try Task.checkCancellation()
    return try result.get()
  }

  /// Clears only the matching access token, preserving newer tokens and refresh credentials.
  public func invalidate(rejectedAccessToken: String) async throws {
    try Task.checkCancellation()
    if cachedToken?.value == rejectedAccessToken {
      cachedToken = nil
    }
  }

  private func refreshAccessToken() async throws -> String {
    defer { refreshTask = nil }
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "grant_type", value: "refresh_token")
    ]
    if let clientSecret {
      form.queryItems?.append(URLQueryItem(name: "client_secret", value: clientSecret))
    }
    // Form decoders interpret literal plus signs as spaces.
    let encodedForm = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    var request = URLRequest(url: Constant.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = encodedForm.map { Data($0.utf8) }

    // Count request time against the token lifetime rather than extending its expiry.
    let requestStartedAt = Date()
    let (data, response) = try await transport.send(request)
    guard response.statusCode == Constant.successStatusCode else {
      let failure = try? JSONDecoder().decode(RefreshFailure.self, from: data)
      if failure?.error == "invalid_grant" {
        throw ProviderError.reauthorizationRequired
      }
      throw ProviderError.requestFailed(statusCode: response.statusCode)
    }
    guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
      !token.access_token.isEmpty,
      token.access_token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      token.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
      token.expires_in >= Constant.minimumTokenLifetime
    else {
      throw ProviderError.invalidResponse
    }
    let expiresAt = requestStartedAt.addingTimeInterval(TimeInterval(token.expires_in))
    guard expiresAt > Date() else { throw ProviderError.invalidResponse }
    cachedToken = CachedToken(value: token.access_token, expiresAt: expiresAt)
    return token.access_token
  }
}

private extension GoogleOAuthTokenProvider {
  struct CachedToken {
    let value: String
    let expiresAt: Date
  }

  struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let token_type: String
  }

  struct RefreshFailure: Decodable {
    let error: String
  }

  enum Constant {
    static let tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!
    static let successStatusCode: Int = 200
    static let minimumTokenLifetime: Int = 1
    static let refreshLeeway: TimeInterval = 30
  }
}

extension GoogleOAuthTokenProvider {
  public enum ProviderError: LocalizedError, Equatable {
    case missingCredentials
    case reauthorizationRequired
    case requestFailed(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
      switch self {
      case .missingCredentials: "Google OAuth credentials are missing."
      case .reauthorizationRequired: "Google sign-in is required."
      case .requestFailed(let statusCode): "Google token refresh failed with HTTP status \(statusCode)."
      case .invalidResponse: "Google returned an unusable access token response."
      }
    }

    public var failureReason: String? {
      switch self {
      case .missingCredentials: "A client ID and refresh token are required."
      case .reauthorizationRequired: "Google rejected the refresh credentials."
      case .requestFailed: "Google's token endpoint did not return a successful response."
      case .invalidResponse: "The response must contain a nonempty Bearer token without whitespace and a positive remaining lifetime."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .missingCredentials: "Supply the OAuth client ID and a refresh token obtained during sign-in."
      case .reauthorizationRequired: "Sign in again and create a provider with the new credentials."
      case .requestFailed: "Check the OAuth client configuration and service availability before retrying."
      case .invalidResponse: "Retry the request and check the token endpoint response format if the problem persists."
      }
    }
  }
}
