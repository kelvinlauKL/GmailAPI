import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Makes read requests for the Google account represented by its token provider.
public struct GmailClient: Sendable {
  private let tokenProvider: any GmailTokenProvider
  private let transport: any GmailTransport
  private let retryPolicy: (any GmailRetryPolicy)?

  /// Supply `ExponentialGmailRetryPolicy()` to enable bounded retries for temporary failures.
  /// With the default `nil` policy, only the single authentication retry is performed.
  public init(
    tokenProvider: any GmailTokenProvider,
    transport: any GmailTransport = URLSessionGmailTransport(),
    retryPolicy: (any GmailRetryPolicy)? = nil
  ) {
    self.tokenProvider = tokenProvider
    self.transport = transport
    self.retryPolicy = retryPolicy
  }

  /// Fetches the authenticated account's mailbox profile.
  /// A rejected access token is invalidated, with one retry using newly requested credentials.
  /// Other HTTP failures return `RequestError.requestFailed` with a `GmailRequestFailure`.
  /// A supplied retry policy handles other HTTP failures and transport errors.
  /// Provider errors, cancellation, and unreadable successful responses propagate without retrying.
  public func profile() async throws -> GmailProfile {
    try await get(Constant.profileEndpoint)
  }

  /// Fetches one page of thread references using the supplied search and pagination options.
  /// Pass the returned `nextPageToken` in a subsequent request to fetch another page.
  /// Uses the same authentication retry and error handling as `profile()`.
  public func listThreads(_ request: GmailThreadListRequest) async throws -> GmailThreadListResponse {
    let url = try requestURL(for: Constant.threadsEndpoint, queryItems: request.queryItems)
    return try await get(url)
  }

  /// Creates a lazy sequence of thread-list pages, starting at the supplied page token.
  /// Each iterator preserves the search and filters and uses this client's credentials,
  /// transport, and retry policy. No request is sent until a page is requested.
  /// Breaking out of iteration stops further fetching; an error finishes that iterator.
  public func threadPages(_ request: GmailThreadListRequest) -> GmailThreadPageSequence {
    GmailThreadPageSequence(client: self, request: request)
  }

  /// Fetches one page of mailbox changes after the supplied starting history ID.
  /// Pass the returned `nextPageToken` with the same starting ID and filters to fetch another page.
  /// Uses the same authentication retry and error handling as `profile()`.
  /// A `requestFailed` error with a `.historyExpired` category requires a full mailbox sync.
  public func listHistory(_ request: GmailHistoryListRequest) async throws -> GmailHistoryListResponse {
    let url = try requestURL(for: Constant.historyEndpoint, queryItems: request.queryItems)
    return try await get(url, failureContext: .historyList)
  }

  /// Creates a lazy sequence of history pages, starting at the supplied page token.
  /// The original `startHistoryId` and filters are preserved across every page.
  /// Each iterator uses this client's credentials, transport, and retry policy.
  /// Save the final page's `historyId` only after every page has been processed successfully.
  /// Breaking out of iteration stops further fetching; an error finishes that iterator.
  /// Expired history propagates as a `requestFailed` error with a `.historyExpired` category.
  public func historyPages(_ request: GmailHistoryListRequest) -> GmailHistoryPageSequence {
    GmailHistoryPageSequence(client: self, request: request)
  }

  /// Fetches a conversation with message bodies in Gmail's parsed MIME format.
  /// Supply the original thread ID; it is encoded as one URL path segment.
  /// Empty IDs and the path segments `.` and `..` are rejected before requesting credentials.
  /// Uses the same authentication retry and error handling as `profile()`.
  public func thread(id: String) async throws -> GmailThread {
    let encodedThreadID = try encodedPathSegment(id, invalidIDError: .invalidThreadID)
    guard var urlComponents = URLComponents(
      url: Constant.threadsEndpoint, resolvingAgainstBaseURL: false
    ) else {
      throw RequestError.invalidRequestURL
    }
    urlComponents.percentEncodedPath += "/\(encodedThreadID)"
    urlComponents.queryItems = [URLQueryItem(name: "format", value: "full")]
    guard let url = urlComponents.url else { throw RequestError.invalidRequestURL }
    return try await get(url)
  }

  /// Fetches an attachment or separately stored MIME body as decoded bytes.
  /// Supply the original message and attachment IDs; each is encoded as one URL path segment.
  /// Empty IDs and the path segments `.` and `..` are rejected before requesting credentials.
  /// Requires a data field and verifies its byte count against the response's size when supplied.
  /// Missing or malformed content and size mismatches throw `RequestError.invalidResponse`.
  /// Uses the same authentication retry and error handling as `profile()`.
  public func attachment(messageID: String, attachmentID: String) async throws -> Data {
    let encodedMessageID = try encodedPathSegment(messageID, invalidIDError: .invalidMessageID)
    let encodedAttachmentID = try encodedPathSegment(attachmentID, invalidIDError: .invalidAttachmentID)
    guard var urlComponents = URLComponents(
      url: Constant.messagesEndpoint, resolvingAgainstBaseURL: false
    ) else {
      throw RequestError.invalidRequestURL
    }
    urlComponents.percentEncodedPath += "/\(encodedMessageID)/attachments/\(encodedAttachmentID)"
    guard let url = urlComponents.url else { throw RequestError.invalidRequestURL }

    let body: GmailMessagePartBody = try await get(url)
    guard let decodedContent = try? body.decodedData() else {
      throw RequestError.invalidResponse
    }
    if let expectedSize = body.size, expectedSize != decodedContent.count {
      throw RequestError.invalidResponse
    }
    return decodedContent
  }

  private func requestURL(for endpoint: URL, queryItems: [URLQueryItem]) throws -> URL {
    guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw RequestError.invalidRequestURL
    }
    urlComponents.queryItems = queryItems
    // Query decoders can interpret literal plus signs as spaces.
    urlComponents.percentEncodedQuery = urlComponents.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = urlComponents.url else { throw RequestError.invalidRequestURL }
    return url
  }

  private func encodedPathSegment(_ identifier: String, invalidIDError: RequestError) throws -> String {
    // Empty and dot segments can change the endpoint instead of identifying a resource.
    guard !identifier.isEmpty, identifier != ".", identifier != ".." else {
      throw invalidIDError
    }
    guard let encodedIdentifier = identifier.addingPercentEncoding(
      withAllowedCharacters: Constant.unreservedURLCharacters
    ) else {
      throw RequestError.invalidRequestURL
    }
    return encodedIdentifier
  }

  private func get<Response: Decodable>(
    _ url: URL,
    failureContext: GmailRequestFailure.Context = .general
  ) async throws -> Response {
    var retryCount = 0
    var hasRetriedAuthentication = false
    var result: Result<Response, AttemptFailure> = try await performAttempt(url, failureContext: failureContext)
    while case .failure(let failure) = result {
      switch failure {
      case .rejectedAccessToken(let accessToken):
        try await tokenProvider.invalidate(rejectedAccessToken: accessToken)
        guard !hasRetriedAuthentication else { throw RequestError.reauthorizationRequired }
        hasRetriedAuthentication = true
      case .http(let requestFailure):
        guard let retryPolicy, try await retryPolicy.waitBeforeRetry(after: requestFailure, retryCount: retryCount)
        else { throw RequestError.requestFailed(requestFailure) }
        retryCount += 1
      case .transport(let error):
        guard let retryPolicy, try await retryPolicy.waitBeforeRetry(after: error, retryCount: retryCount)
        else { throw error }
        retryCount += 1
      }
      result = try await performAttempt(url, failureContext: failureContext)
    }
    return try result.get()
  }

  private func performAttempt<Response: Decodable>(
    _ url: URL, failureContext: GmailRequestFailure.Context
  ) async throws -> Result<Response, AttemptFailure> {
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
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      try Task.checkCancellation()
      guard !(error is CancellationError), (error as? URLError)?.code != .cancelled
      else { throw error }
      return .failure(.transport(error))
    }
    try Task.checkCancellation()
    if response.statusCode == Constant.unauthorizedStatusCode {
      return .failure(.rejectedAccessToken(accessToken))
    }
    if response.statusCode != Constant.successStatusCode {
      let errorResponse = try? JSONDecoder().decode(GmailErrorResponse.self, from: data)
      let failure = GmailRequestFailure(
        statusCode: response.statusCode,
        details: errorResponse?.error,
        retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
        context: failureContext
      )
      return .failure(.http(failure))
    }
    guard let decodedResponse = try? JSONDecoder().decode(Response.self, from: data) else {
      throw RequestError.invalidResponse
    }
    return .success(decodedResponse)
  }
}

private extension GmailClient {
  /// Internal outcomes for retry coordination; callers receive the original public errors.
  enum AttemptFailure: Error {
    case rejectedAccessToken(String)
    case http(GmailRequestFailure)
    case transport(any Error)
  }

  enum Constant {
    static let profileEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    static let threadsEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
    static let historyEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
    static let messagesEndpoint: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
    static let unreservedURLCharacters: CharacterSet = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    static let successStatusCode: Int = 200
    static let unauthorizedStatusCode: Int = 401
  }
}

public extension GmailClient {
  enum RequestError: LocalizedError, Equatable {
    case invalidRequestURL
    case invalidThreadID
    case invalidMessageID
    case invalidAttachmentID
    case invalidAccessToken
    case reauthorizationRequired
    case requestFailed(GmailRequestFailure)
    case invalidResponse

    public var errorDescription: String? {
      switch self {
      case .invalidRequestURL: "The Gmail request URL could not be constructed."
      case .invalidThreadID: "The Gmail thread ID is invalid."
      case .invalidMessageID: "The Gmail message ID is invalid."
      case .invalidAttachmentID: "The Gmail attachment ID is invalid."
      case .invalidAccessToken: "The credential provider returned an invalid access token."
      case .reauthorizationRequired: "Google sign-in is required."
      case .requestFailed(let failure): failure.errorDescription
      case .invalidResponse: "Gmail returned an unreadable response."
      }
    }

    public var failureReason: String? {
      switch self {
      case .invalidRequestURL: "The request parameters could not be encoded into a valid URL."
      case .invalidThreadID: "The thread ID was empty or was a dot path segment."
      case .invalidMessageID: "The message ID was empty or was a dot path segment."
      case .invalidAttachmentID: "The attachment ID was empty or was a dot path segment."
      case .invalidAccessToken: "The access token was empty or contained whitespace."
      case .reauthorizationRequired: "Gmail rejected the credentials after an authentication retry."
      case .requestFailed(let failure): failure.failureReason
      case .invalidResponse: "The response did not match the expected Gmail data format."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidRequestURL: "Check the request parameters and URL construction before retrying."
      case .invalidThreadID: "Provide the original thread ID returned by Gmail."
      case .invalidMessageID: "Provide the original ID of the message containing the attachment."
      case .invalidAttachmentID: "Provide the original attachmentId returned in the message part body."
      case .invalidAccessToken: "Provide a current access token without whitespace or the Bearer prefix."
      case .reauthorizationRequired: "Sign in again and supply a provider with the new credentials."
      case .requestFailed(let failure): failure.recoverySuggestion
      case .invalidResponse: "Retry the request and check the response format if the problem persists."
      }
    }
  }
}
