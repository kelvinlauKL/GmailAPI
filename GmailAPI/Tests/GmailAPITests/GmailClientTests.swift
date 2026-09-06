import Foundation
import Testing
import GmailAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GmailClientTests {
  @Test
  func fetchesAndDecodesAuthenticatedProfile() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    let profile = try await client.profile()

    #expect(profile.emailAddress == "demo@example.com")
    #expect(profile.messagesTotal == 50)
    #expect(profile.threadsTotal == 12)
    #expect(profile.historyId == "18446744073709551615")
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func requestsCredentialsForEveryProfileCall() async throws {
    let tokenProvider = TokenProvider(tokens: ["first-token", "second-token"])
    let transport = Transport()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    _ = try await client.profile()
    _ = try await client.profile()

    let authorizationHeaders = await transport.requests.map {
      $0.value(forHTTPHeaderField: "Authorization")
    }
    #expect(authorizationHeaders == ["Bearer first-token", "Bearer second-token"])
    #expect(await tokenProvider.retrievalCount == 2)
  }

  @Test(arguments: ["", " ", "Bearer token", "token\nvalue", "token\rvalue", "token\tvalue"])
  func rejectsInvalidTokensBeforeSending(accessToken: String) async throws {
    let tokenProvider = TokenProvider(tokens: [accessToken])
    let transport = Transport()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidAccessToken) {
      try await client.profile()
    }
    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func retriesUnauthorizedRequestWithFreshCredentials() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(statusCodes: [401, 200])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    #expect(try await client.profile().emailAddress == "demo@example.com")

    let requests = await transport.requests
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(requests.first?.url == requests.last?.url)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
    #expect(await tokenProvider.retrievalCount == 2)
  }

  @Test
  func stopsAfterSecondRejectionAndInvalidatesBothTokens() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "also-rejected-token"])
    let transport = Transport(statusCodes: [401, 401, 200])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.reauthorizationRequired) {
      try await client.profile()
    }
    #expect(await transport.requests.count == 2)
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token", "also-rejected-token"])
  }

  @Test
  func permitsRetryWhenProviderReturnsSameTokenValue() async throws {
    let tokenProvider = TokenProvider(tokens: ["same-token", "same-token"])
    let transport = Transport(statusCodes: [401, 200])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    _ = try await client.profile()

    #expect(await transport.requests.count == 2)
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["same-token"])
  }

  @Test
  func validatesReplacementTokenBeforeRetrying() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "invalid replacement"])
    let transport = Transport(statusCodes: [401, 200])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidAccessToken) {
      try await client.profile()
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test(arguments: [204, 302, 400, 403, 404, 429, 500, 503])
  func preservesOtherHTTPFailuresWithoutRetryOrPrivateResponse(statusCode: Int) async throws {
    let tokenProvider = TokenProvider()
    let privateResponse = "private-response-content"
    let transport = Transport(statusCodes: [statusCode], responseBody: privateResponse)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    do {
      _ = try await client.profile()
      Issue.record("Expected an HTTP failure.")
    } catch let error as GmailClient.RequestError {
      #expect(error == .requestFailed(statusCode: statusCode))
      let failureReason = try #require(error.failureReason)
      let recoverySuggestion = try #require(error.recoverySuggestion)
      #expect(!error.localizedDescription.contains(privateResponse))
      #expect(!failureReason.contains(privateResponse))
      #expect(!recoverySuggestion.contains(privateResponse))
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: ["not json", "{}", #"{"emailAddress":"private-response-content"}"#])
  func rejectsMalformedProfileWithoutRetry(responseBody: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await client.profile()
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: DependencyFailure.allCases)
  func propagatesDependencyFailuresWithoutRetry(failure: DependencyFailure) async throws {
    let tokenProvider = TokenProvider(failure: failure)
    let transport = Transport(
      statusCodes: failure == .invalidation ? [401] : [200], failure: failure
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: failure) { try await client.profile() }

    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await transport.requests.count == (failure == .credentials ? 0 : 1))
    #expect(await tokenProvider.invalidatedTokens.count == (failure == .invalidation ? 1 : 0))
  }

  @Test(arguments: CancellationStage.allCases)
  func cancellationStopsSubsequentWork(stage: CancellationStage) async throws {
    let tokenProvider = TokenProvider(cancellationStage: stage)
    let transport = Transport(statusCodes: [401], cancellationStage: stage)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let cancelledTask = Task {
      if stage == .beforeCredentials {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
      return try await client.profile()
    }

    await #expect(throws: CancellationError.self) { try await cancelledTask.value }

    #expect(await tokenProvider.retrievalCount == (stage == .beforeCredentials ? 0 : 1))
    let expectedRequestCount = (stage == .response || stage == .invalidation) ? 1 : 0
    #expect(await transport.requests.count == expectedRequestCount)
    #expect(await tokenProvider.invalidatedTokens.count == (stage == .invalidation ? 1 : 0))
  }

  enum CancellationStage: CaseIterable, Sendable {
    case beforeCredentials, credentials, response, invalidation
  }

  enum DependencyFailure: LocalizedError, Equatable, CaseIterable {
    case credentials, invalidation, transport

    var errorDescription: String? { "The test dependency failed." }
    var failureReason: String? { "The dependency was configured to fail." }
    var recoverySuggestion: String? { "Supply a working test dependency." }
  }

  private actor TokenProvider: GmailTokenProvider {
    private let tokens: [String]
    private let failure: DependencyFailure?
    private let cancellationStage: CancellationStage?
    private(set) var retrievalCount = 0
    private(set) var invalidatedTokens: [String] = []

    init(
      tokens: [String] = ["first-token"],
      failure: DependencyFailure? = nil,
      cancellationStage: CancellationStage? = nil
    ) {
      self.tokens = tokens
      self.failure = failure
      self.cancellationStage = cancellationStage
    }

    func accessToken() async throws -> String {
      retrievalCount += 1
      if failure == .credentials { throw DependencyFailure.credentials }
      if cancellationStage == .credentials {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
      // Repeat the last token to let unexpected extra requests reach the assertions.
      return tokens[min(retrievalCount - 1, tokens.count - 1)]
    }

    func invalidate(rejectedAccessToken: String) async throws {
      invalidatedTokens.append(rejectedAccessToken)
      if failure == .invalidation { throw DependencyFailure.invalidation }
      if cancellationStage == .invalidation {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
    }
  }

  private actor Transport: GmailTransport {
    private let statusCodes: [Int]
    private let responseBody: String
    private let failure: DependencyFailure?
    private let cancellationStage: CancellationStage?
    private(set) var requests: [URLRequest] = []

    init(
      statusCodes: [Int] = [200],
      responseBody: String = """
        {"emailAddress":"demo@example.com","messagesTotal":50,"threadsTotal":12,"historyId":"18446744073709551615"}
        """,
      failure: DependencyFailure? = nil,
      cancellationStage: CancellationStage? = nil
    ) {
      self.statusCodes = statusCodes
      self.responseBody = responseBody
      self.failure = failure
      self.cancellationStage = cancellationStage
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      requests.append(request)
      if failure == .transport { throw DependencyFailure.transport }
      if cancellationStage == .response {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
      let statusCode = statusCodes[min(requests.count - 1, statusCodes.count - 1)]
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: statusCode,
        httpVersion: nil, headerFields: nil
      ))
      return (Data(responseBody.utf8), response)
    }
  }
}
