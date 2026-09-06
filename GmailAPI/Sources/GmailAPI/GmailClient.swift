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
    try await get(Constant.profileEndpoint)
  }

  /// Fetches one page of thread references using the supplied search and pagination options.
  /// Pass the returned `nextPageToken` in a subsequent request to fetch another page.
  /// Uses the same authentication retry and error handling as `profile()`.
  public func listThreads(_ request: GmailThreadListRequest) async throws -> GmailThreadListResponse {
    guard var urlComponents = URLComponents(
      url: Constant.threadsEndpoint, resolvingAgainstBaseURL: false
    ) else {
      throw RequestError.invalidRequestURL
    }
    urlComponents.queryItems = request.queryItems
    // Query decoders can interpret literal plus signs as spaces.
    urlComponents.percentEncodedQuery = urlComponents.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = urlComponents.url else { throw RequestError.invalidRequestURL }
    return try await get(url)
  }

  /// Fetches a conversation with message bodies in Gmail's parsed MIME format.
  /// Supply the original thread ID; it is encoded as one URL path segment.
  /// Empty IDs and the path segments `.` and `..` are rejected before requesting credentials.
  /// Uses the same authentication retry and error handling as `profile()`.
  public func thread(id: String) async throws -> GmailThread {
    guard !id.isEmpty, id != ".", id != ".." else {
      throw RequestError.invalidThreadID
    }
    guard let encodedThreadID = id.addingPercentEncoding(
      withAllowedCharacters: Constant.unreservedURLCharacters
    ), var urlComponents = URLComponents(
      url: Constant.threadsEndpoint, resolvingAgainstBaseURL: false
    ) else {
      throw RequestError.invalidRequestURL
    }
    urlComponents.percentEncodedPath += "/\(encodedThreadID)"
    urlComponents.queryItems = [URLQueryItem(name: "format", value: "full")]
    guard let url = urlComponents.url else { throw RequestError.invalidRequestURL }
    return try await get(url)
  }

  private func get<Response: Decodable>(
    _ url: URL, canRetryAuthentication: Bool = true
  ) async throws -> Response {
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
      guard canRetryAuthentication else { throw RequestError.reauthorizationRequired }
      return try await get(url, canRetryAuthentication: false)
    }
    guard response.statusCode == Constant.successStatusCode else {
      throw RequestError.requestFailed(statusCode: response.statusCode)
    }
    guard let decodedResponse = try? JSONDecoder().decode(Response.self, from: data) else {
      throw RequestError.invalidResponse
    }
    return decodedResponse
  }

  private enum Constant {
    static let profileEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    static let threadsEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
    static let unreservedURLCharacters: CharacterSet = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    static let successStatusCode: Int = 200
    static let unauthorizedStatusCode: Int = 401
  }

  public enum RequestError: LocalizedError, Equatable {
    case invalidRequestURL
    case invalidThreadID
    case invalidAccessToken
    case reauthorizationRequired
    case requestFailed(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
      switch self {
      case .invalidRequestURL: "The Gmail request URL could not be constructed."
      case .invalidThreadID: "The Gmail thread ID is invalid."
      case .invalidAccessToken: "The credential provider returned an invalid access token."
      case .reauthorizationRequired: "Google sign-in is required."
      case .requestFailed(let statusCode): "The Gmail request failed with HTTP status \(statusCode)."
      case .invalidResponse: "Gmail returned an unreadable response."
      }
    }

    public var failureReason: String? {
      switch self {
      case .invalidRequestURL: "The request parameters could not be encoded into a valid URL."
      case .invalidThreadID: "The thread ID was empty or was a dot path segment."
      case .invalidAccessToken: "The access token was empty or contained whitespace."
      case .reauthorizationRequired: "Gmail rejected the credentials after an authentication retry."
      case .requestFailed: "Gmail did not return the expected successful HTTP status."
      case .invalidResponse: "The response did not match the expected Gmail data format."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidRequestURL: "Check the request parameters and URL construction before retrying."
      case .invalidThreadID: "Provide the original thread ID returned by Gmail."
      case .invalidAccessToken: "Provide a current access token without whitespace or the Bearer prefix."
      case .reauthorizationRequired: "Sign in again and supply a provider with the new credentials."
      case .requestFailed: "Check the HTTP status, account permissions, quota, and service availability before retrying."
      case .invalidResponse: "Retry the request and check the response format if the problem persists."
      }
    }
  }
}
