import Foundation
import Testing
import GmailAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GoogleOAuthTokenProviderTests {
  @Test
  func refreshesThroughProtocolAndCachesToken() async throws {
    let endpoint = TokenEndpoint()
    let provider: any GmailTokenProvider = try makeProvider(endpoint: endpoint)

    #expect(try await provider.accessToken() == "access-token-1")
    #expect(try await provider.accessToken() == "access-token-1")
    let requests = await endpoint.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try formFields(in: request) == [
      "client_id": "test-client", "refresh_token": "test-refresh-token", "grant_type": "refresh_token"
    ])
  }

  @Test
  func encodesCredentialsWithoutChangingSpecialCharacters() async throws {
    let endpoint = TokenEndpoint()
    let specialValue = "value+with spaces/&=%?雪"
    let provider = try GoogleOAuthTokenProvider(
      clientID: specialValue,
      clientSecret: specialValue,
      refreshToken: specialValue,
      transport: endpoint
    )

    _ = try await provider.accessToken()

    let request = try #require(await endpoint.requests.first)
    #expect(try formFields(in: request) == [
      "client_id": specialValue, "client_secret": specialValue,
      "refresh_token": specialValue, "grant_type": "refresh_token"
    ])
  }

  @Test
  func refreshesNearExpiry() async throws {
    let endpoint = TokenEndpoint(tokenLifetime: 10)
    let provider = try makeProvider(endpoint: endpoint)

    #expect(try await provider.accessToken() == "access-token-1")
    #expect(try await provider.accessToken() == "access-token-2")
    #expect(await endpoint.requests.count == 2)
  }

  @Test
  func invalidationPreservesNewerTokenAndRefreshCredentials() async throws {
    let endpoint = TokenEndpoint()
    let provider = try makeProvider(endpoint: endpoint)
    let originalToken = try await provider.accessToken()
    try await provider.invalidate(rejectedAccessToken: originalToken)
    #expect(await endpoint.requests.count == 1)

    #expect(try await provider.accessToken() == "access-token-2")
    try await provider.invalidate(rejectedAccessToken: originalToken)
    #expect(try await provider.accessToken() == "access-token-2")

    let requests = await endpoint.requests
    #expect(requests.count == 2)
    for request in requests {
      #expect(try formFields(in: request)["refresh_token"] == "test-refresh-token")
    }
  }

  @Test
  func concurrentCallersShareRefresh() async throws {
    let endpoint = TokenEndpoint(paused: true)
    let provider = try makeProvider(endpoint: endpoint)

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<20 {
        group.addTask { try await provider.accessToken() }
      }
      await endpoint.waitForRequest()
      await endpoint.releaseResponses()
      var tokens: [String] = []
      for try await token in group { tokens.append(token) }
      return tokens
    }

    #expect(tokens.count == 20)
    #expect(Set(tokens) == ["access-token-1"])
    #expect(await endpoint.requests.count == 1)
  }

  @Test(arguments: [
    "{}", "not json",
    #"{"access_token":"","expires_in":3600,"token_type":"Bearer"}"#,
    #"{"access_token":"Bearer token","expires_in":3600,"token_type":"Bearer"}"#,
    #"{"access_token":"secret\ntoken","expires_in":3600,"token_type":"Bearer"}"#,
    #"{"access_token":"secret","expires_in":0,"token_type":"Bearer"}"#,
    #"{"access_token":"secret","expires_in":-1,"token_type":"Bearer"}"#,
    #"{"access_token":"secret","expires_in":3600,"token_type":"Other"}"#
  ])
  func rejectsMalformedTokensAndCanRetry(responseBody: String) async throws {
    let endpoint = TokenEndpoint(firstResponseBody: responseBody)
    let provider = try makeProvider(endpoint: endpoint)

    await #expect(throws: GoogleOAuthTokenProvider.ProviderError.invalidResponse) {
      try await provider.accessToken()
    }
    #expect(try await provider.accessToken() == "access-token-2")
  }

  @Test
  func reportsRejectedRefreshCredentialsWithoutLeakingResponse() async throws {
    let endpoint = TokenEndpoint(
      firstResponseBody: #"{"error":"invalid_grant","error_description":"private-credential"}"#,
      firstStatusCode: 400
    )
    let provider = try makeProvider(endpoint: endpoint)

    await #expect(throws: GoogleOAuthTokenProvider.ProviderError.reauthorizationRequired) {
      try await provider.accessToken()
    }
    let error = GoogleOAuthTokenProvider.ProviderError.reauthorizationRequired
    #expect(error.localizedDescription == "Google sign-in is required.")
    #expect(error.failureReason == "Google rejected the refresh credentials.")
    #expect(error.recoverySuggestion == "Sign in again and create a provider with the new credentials.")
  }

  @Test
  func canRetryAfterHTTPFailure() async throws {
    let endpoint = TokenEndpoint(firstResponseBody: "unavailable", firstStatusCode: 503)
    let provider = try makeProvider(endpoint: endpoint)

    await #expect(throws: GoogleOAuthTokenProvider.ProviderError.requestFailed(statusCode: 503)) {
      try await provider.accessToken()
    }
    #expect(try await provider.accessToken() == "access-token-2")
  }

  @Test
  func canRetryAfterNetworkFailure() async throws {
    let endpoint = TokenEndpoint(failFirstRequest: true)
    let provider = try makeProvider(endpoint: endpoint)

    do {
      _ = try await provider.accessToken()
      Issue.record("Expected the network failure to propagate.")
    } catch let error as URLError {
      #expect(error.code == .notConnectedToInternet)
    }
    #expect(try await provider.accessToken() == "access-token-2")
  }

  @Test
  func rejectsMissingCredentials() {
    #expect(throws: GoogleOAuthTokenProvider.ProviderError.missingCredentials) {
      try GoogleOAuthTokenProvider(clientID: " ", refreshToken: "test-refresh-token")
    }
    #expect(throws: GoogleOAuthTokenProvider.ProviderError.missingCredentials) {
      try GoogleOAuthTokenProvider(clientID: "test-client", refreshToken: "")
    }
  }

  @Test
  func cancelledCallerDoesNotStartRefreshOrInvalidateCache() async throws {
    let endpoint = TokenEndpoint()
    let provider = try makeProvider(endpoint: endpoint)
    let token = try await provider.accessToken()
    let cancelledTask = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: CancellationError.self) { try await provider.accessToken() }
      await #expect(throws: CancellationError.self) {
        try await provider.invalidate(rejectedAccessToken: token)
      }
    }
    await cancelledTask.value

    #expect(try await provider.accessToken() == token)
    #expect(await endpoint.requests.count == 1)
  }

  @Test
  func cancellationDoesNotDiscardSharedRefresh() async throws {
    let endpoint = TokenEndpoint(paused: true)
    let provider = try makeProvider(endpoint: endpoint)
    let cancelledCaller = Task { try await provider.accessToken() }
    await endpoint.waitForRequest()
    cancelledCaller.cancel()
    let otherCaller = Task { try await provider.accessToken() }
    await endpoint.releaseResponses()

    await #expect(throws: CancellationError.self) { try await cancelledCaller.value }
    #expect(try await otherCaller.value == "access-token-1")
    #expect(try await provider.accessToken() == "access-token-1")
    #expect(await endpoint.requests.count == 1)
  }

  private func makeProvider(endpoint: TokenEndpoint) throws -> GoogleOAuthTokenProvider {
    try GoogleOAuthTokenProvider(
      clientID: "test-client", refreshToken: "test-refresh-token",
      transport: endpoint
    )
  }

  private func formFields(in request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    let encodedForm = try #require(String(data: body, encoding: .utf8))
    var components = URLComponents()
    components.percentEncodedQuery = encodedForm.replacingOccurrences(of: "+", with: "%20")
    let queryItems = try #require(components.queryItems)
    var fields: [String: String] = [:]
    for queryItem in queryItems { fields[queryItem.name] = queryItem.value }
    return fields
  }
}

private extension GoogleOAuthTokenProviderTests {
  actor TokenEndpoint: GmailTransport {
    private(set) var requests: [URLRequest] = []
    private let tokenLifetime: Int
    private let firstResponseBody: String?
    private let firstStatusCode: Int
    private let failFirstRequest: Bool
    private var paused: Bool
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
      tokenLifetime: Int = 3600,
      firstResponseBody: String? = nil,
      firstStatusCode: Int = 200,
      failFirstRequest: Bool = false,
      paused: Bool = false
    ) {
      self.tokenLifetime = tokenLifetime
      self.firstResponseBody = firstResponseBody
      self.firstStatusCode = firstStatusCode
      self.failFirstRequest = failFirstRequest
      self.paused = paused
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      requests.append(request)
      let requestNumber = requests.count
      for waiter in requestWaiters { waiter.resume() }
      requestWaiters.removeAll()
      if paused {
        await withCheckedContinuation { responseWaiters.append($0) }
      }
      if requestNumber == 1, failFirstRequest { throw URLError(.notConnectedToInternet) }
      let responseBody = requestNumber == 1 ? firstResponseBody : nil
      let defaultBody = """
        {"access_token":"access-token-\(requestNumber)","expires_in":\(tokenLifetime),"token_type":"Bearer","scope":"ignored"}
        """
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: requestNumber == 1 ? firstStatusCode : 200,
        httpVersion: nil, headerFields: nil
      ))
      return (Data((responseBody ?? defaultBody).utf8), response)
    }

    func waitForRequest() async {
      if requests.isEmpty {
        await withCheckedContinuation { requestWaiters.append($0) }
      }
    }

    func releaseResponses() {
      paused = false
      for waiter in responseWaiters { waiter.resume() }
      responseWaiters.removeAll()
    }
  }
}
