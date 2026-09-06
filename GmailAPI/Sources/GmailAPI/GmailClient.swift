import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Makes read requests for the Google account represented by its token provider.
public struct GmailClient: Sendable {
  private let tokenProvider: any GmailTokenProvider
  private let transport: any GmailTransport

  public init(
    tokenProvider: any GmailTokenProvider,
    transport: any GmailTransport = URLSessionGmailTransport()
  ) {
    self.tokenProvider = tokenProvider
    self.transport = transport
  }

  /// Fetches the authenticated account's mailbox profile.
  /// A rejected access token is invalidated, with one retry using newly requested credentials.
  /// Other HTTP failures are returned without retrying. Provider and transport errors propagate.
  public func profile() async throws -> GmailProfile {
    let data = try await get(Constant.profileEndpoint)
    guard let profile = try? JSONDecoder().decode(GmailProfile.self, from: data) else {
      throw RequestError.invalidResponse
    }
    return profile
  }

  private func get(_ url: URL, canRetryAuthentication: Bool = true) async throws -> Data {
    try Task.checkCancellation()
    let accessToken = try await tokenProvider.accessToken()
    try Task.checkCancellation()
    guard !accessToken.isEmpty,
      accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw RequestError.invalidAccessToken
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await transport.send(request)
    try Task.checkCancellation()
    if response.statusCode == Constant.unauthorizedStatusCode {
      try await tokenProvider.invalidate(rejectedAccessToken: accessToken)
      try Task.checkCancellation()
      guard canRetryAuthentication else { throw RequestError.reauthorizationRequired }
      return try await get(url, canRetryAuthentication: false)
    }
    guard response.statusCode == Constant.successStatusCode else {
      throw RequestError.requestFailed(statusCode: response.statusCode)
    }
    return data
  }

  private enum Constant {
    static let profileEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    static let successStatusCode: Int = 200
    static let unauthorizedStatusCode: Int = 401
  }

  public enum RequestError: LocalizedError, Equatable {
    case invalidAccessToken
    case reauthorizationRequired
    case requestFailed(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
      switch self {
      case .invalidAccessToken: "The credential provider returned an invalid access token."
      case .reauthorizationRequired: "Google sign-in is required."
      case .requestFailed(let statusCode): "The Gmail request failed with HTTP status \(statusCode)."
      case .invalidResponse: "Gmail returned an unreadable response."
      }
    }

    public var failureReason: String? {
      switch self {
      case .invalidAccessToken: "The access token was empty or contained whitespace."
      case .reauthorizationRequired: "Gmail rejected the credentials after an authentication retry."
      case .requestFailed: "Gmail did not return the expected successful HTTP status."
      case .invalidResponse: "The response did not match the expected Gmail data format."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidAccessToken: "Provide a current access token without whitespace or the Bearer prefix."
      case .reauthorizationRequired: "Sign in again and supply a provider with the new credentials."
      case .requestFailed: "Check the HTTP status, account permissions, quota, and service availability before retrying."
      case .invalidResponse: "Retry the request and check the response format if the problem persists."
      }
    }
  }
}
