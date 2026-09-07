import Foundation
import GmailAPI
import GmailSync
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GmailBootstrapDiscoveryTests {
  @Test
  func startCapturesOnlyTheProfileBaseline() async throws {
    let transport = Transport(replies: [.response(Constant.profileResponse)])
    let tokenProvider = TokenProvider()
    let loader = try GmailBootstrapDiscovery(
      client: GmailClient(tokenProvider: tokenProvider, transport: transport), accountID: "account"
    )
    let generation = UUID()
    let policy = try GmailSyncPolicy(version: 3, requiredLabelIds: ["Work"])

    #expect(await transport.requests.isEmpty)
    let checkpoint = try await loader.start(importGeneration: generation, policy: policy, maxResults: 37)

    #expect(checkpoint.accountID == "account")
    #expect(checkpoint.importGeneration == generation)
    #expect(checkpoint.policy == policy)
    #expect(checkpoint.baselineHistoryId == "000100")
    #expect(checkpoint.maxResults == 37)
    #expect(checkpoint.position == .listing(pageToken: nil))
    #expect(await transport.requests.map(\.url?.path) == ["/gmail/v1/users/me/profile"])
    #expect(await tokenProvider.retrievalCount == 1)
  }

  @Test
  func fetchesOnePageAtATimeAndResumesWithoutReplacingTheBaseline() async throws {
    let transport = Transport(replies: [
      .response(Constant.profileResponse),
      .response(#"{"threads":[{"id":"b"},{"id":"a"},{"id":"b"}],"nextPageToken":"next+/=%2F"}"#),
      .response(#"{"threads":[],"resultSizeEstimate":999}"#)
    ])
    let loader = try makeLoader(transport: transport)
    let policy = try GmailSyncPolicy(version: 2, requiredLabelIds: ["Work"], includeSpamTrash: true)
    let initial = try await loader.start(importGeneration: UUID(), policy: policy, maxResults: 37)
    #expect(await transport.requests.count == 1)

    let first = try #require(try await loader.nextPage(after: initial))
    #expect(await transport.requests.count == 2)
    #expect(first.expectedCheckpoint == initial)
    #expect(first.discoveryPage.importGeneration == initial.importGeneration)
    #expect(first.discoveryPage.conversationIDs.map(\.threadID) == ["a", "b"])
    #expect(first.nextCheckpoint.position == .listing(pageToken: "next+/=%2F"))
    #expect(initial.position == .listing(pageToken: nil))

    let restored = try JSONDecoder().decode(
      GmailBootstrapCheckpoint.self, from: JSONEncoder().encode(first.nextCheckpoint)
    )
    let resumedLoader = try makeLoader(transport: transport)
    let final = try #require(try await resumedLoader.nextPage(after: restored))
    #expect(final.expectedCheckpoint == restored)
    #expect(final.discoveryPage.conversationIDs.isEmpty)
    #expect(final.nextCheckpoint.position == .awaitingHistoryReplay)
    #expect(try final.nextCheckpoint.makeHistoryCheckpoint().historyId == "000100")
    #expect(try await resumedLoader.nextPage(after: final.nextCheckpoint) == nil)

    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == [
      "/gmail/v1/users/me/profile", "/gmail/v1/users/me/threads", "/gmail/v1/users/me/threads"
    ])
    for (request, token) in zip(requests.dropFirst(), [nil, "next+/=%2F"] as [String?]) {
      let url = try #require(request.url)
      let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
      var expectedItems = [URLQueryItem(name: "maxResults", value: "37"), URLQueryItem(name: "includeSpamTrash", value: "true")]
      if let token { expectedItems.append(URLQueryItem(name: "pageToken", value: token)) }
      #expect(components.queryItems == expectedItems)
      #expect(components.percentEncodedQuery?.contains("+") == false)
    }
  }

  @Test
  func completedEnumerationDoesNotRequestCredentialsOrNetwork() async throws {
    let transport = Transport(replies: [])
    let tokenProvider = TokenProvider()
    let loader = try GmailBootstrapDiscovery(
      client: GmailClient(tokenProvider: tokenProvider, transport: transport), accountID: "account"
    )
    let completed = try makeCheckpoint(position: .awaitingHistoryReplay)

    #expect(try await loader.nextPage(after: completed) == nil)
    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.retrievalCount == 0)
  }

  @Test(arguments: [false, true])
  func rejectsAnotherAccountsCheckpointBeforeAnyIO(completed: Bool) async throws {
    let transport = Transport(replies: [])
    let loader = try makeLoader(transport: transport)
    let otherAccount = try makeCheckpoint(
      accountID: "other", position: completed ? .awaitingHistoryReplay : .listing(pageToken: nil)
    )

    await #expect(throws: GmailBootstrapCheckpoint.TransitionError.accountMismatch) {
      try await loader.nextPage(after: otherAccount)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankAccountBindings(accountID: String) async throws {
    let transport = Transport(replies: [])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)

    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailBootstrapDiscovery(client: client, accountID: accountID)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: [0, -1, 501])
  func validatesPageSizeBeforeFetchingTheBaseline(maxResults: Int) async throws {
    let transport = Transport(replies: [])
    let tokenProvider = TokenProvider()
    let loader = try GmailBootstrapDiscovery(
      client: GmailClient(tokenProvider: tokenProvider, transport: transport), accountID: "account"
    )
    let policy = try GmailSyncPolicy(version: 1)

    await #expect(throws: GmailThreadListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try await loader.start(importGeneration: UUID(), policy: policy, maxResults: maxResults)
    }
    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.retrievalCount == 0)
  }

  @Test
  func preservesProfileFailuresWithoutStartingAListing() async throws {
    let transport = Transport(replies: [.response("{}", statusCode: 503)])
    let loader = try makeLoader(transport: transport)

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: 503))) {
      try await loader.start(importGeneration: UUID(), policy: GmailSyncPolicy(version: 1))
    }
    #expect(await transport.requests.map(\.url?.path) == ["/gmail/v1/users/me/profile"])
  }

  @Test
  func rejectsAnUnusableBaselineInsteadOfReturningACheckpoint() async throws {
    let body = #"{"emailAddress":"demo@example.com","messagesTotal":0,"threadsTotal":0,"historyId":" "}"#
    let transport = Transport(replies: [.response(body)])
    let loader = try makeLoader(transport: transport)

    await #expect(throws: GmailHistoryListRequest.ValidationError.missingStartHistoryID) {
      try await loader.start(importGeneration: UUID(), policy: GmailSyncPolicy(version: 1))
    }
    #expect(await transport.requests.count == 1)
  }

  @Test
  func rejectsAnUnreadableProfile() async throws {
    let transport = Transport(replies: [.response("{}")])
    let loader = try makeLoader(transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await loader.start(importGeneration: UUID(), policy: GmailSyncPolicy(version: 1))
    }
  }

  @Test
  func aFailedPageCanBeRetriedFromTheSameSavedCheckpoint() async throws {
    let transport = Transport(replies: [
      .response("{}", statusCode: 503), .response(#"{"threads":[{"id":"retry"}],"nextPageToken":"next"}"#)
    ])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint(position: .listing(pageToken: "saved"))

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: 503))) {
      try await loader.nextPage(after: checkpoint)
    }
    let retried = try #require(try await loader.nextPage(after: checkpoint))

    #expect(retried.expectedCheckpoint == checkpoint)
    #expect(retried.nextCheckpoint.position == .listing(pageToken: "next"))
    #expect(checkpoint.position == .listing(pageToken: "saved"))
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0] == requests[1])
  }

  @Test
  func preservesTransportFailures() async throws {
    let transport = Transport(replies: [.failure(.timedOut)])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint()

    await #expect(throws: URLError(.timedOut)) { try await loader.nextPage(after: checkpoint) }
    #expect(checkpoint.position == .listing(pageToken: nil))
  }

  @Test
  func rejectsUnreadableListingResponses() async throws {
    let transport = Transport(replies: [.response(#"{"threads":"invalid"}"#)])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint()

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await loader.nextPage(after: checkpoint)
    }
  }

  @Test
  func malformedConversationIDsDoNotYieldASuccessor() async throws {
    let transport = Transport(replies: [.response(#"{"threads":[{"id":"valid"},{"id":""}]}"#)])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint()

    await #expect(throws: GmailConversationID.ValidationError.emptyThreadID) {
      try await loader.nextPage(after: checkpoint)
    }
    #expect(checkpoint.position == .listing(pageToken: nil))
  }

  @Test
  func repeatedContinuationTokensDoNotYieldASuccessor() async throws {
    let transport = Transport(replies: [.response(#"{"nextPageToken":"same"}"#)])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint(position: .listing(pageToken: "same"))

    await #expect(throws: GmailBootstrapCheckpoint.TransitionError.repeatedPageToken) {
      try await loader.nextPage(after: checkpoint)
    }
    #expect(checkpoint.position == .listing(pageToken: "same"))
  }

  @Test(arguments: [false, true], [false, true])
  func propagatesCancellationBeforeOrDuringEachRequest(startingImport: Bool, duringRequest: Bool) async throws {
    let body = startingImport ? Constant.profileResponse : "{}"
    let transport = Transport(replies: duringRequest ? [.cancellation(body)] : [])
    let loader = try makeLoader(transport: transport)
    let checkpoint = try makeCheckpoint()
    let requestTask = Task {
      if !duringRequest { withUnsafeCurrentTask { currentTask in currentTask?.cancel() } }
      await #expect(throws: CancellationError.self) {
        if startingImport {
          _ = try await loader.start(importGeneration: UUID(), policy: checkpoint.policy)
        } else {
          _ = try await loader.nextPage(after: checkpoint)
        }
      }
    }

    await requestTask.value
    #expect(await transport.requests.count == (duringRequest ? 1 : 0))
  }
}

private extension GmailBootstrapDiscoveryTests {
  enum Constant {
    static let profileResponse: String = #"{"emailAddress":"demo@example.com","messagesTotal":2,"threadsTotal":1,"historyId":"000100"}"#
  }

  enum Reply: Sendable {
    case response(String, statusCode: Int = 200)
    case failure(URLError.Code)
    case cancellation(String)
  }

  actor TokenProvider: GmailTokenProvider {
    private(set) var retrievalCount: Int = 0

    func accessToken() async throws -> String {
      retrievalCount += 1
      return "test-token"
    }

    func invalidate(rejectedAccessToken: String) async throws {}
  }

  actor Transport: GmailTransport {
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) {
      self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      requests.append(request)
      let reply = try #require(replies.first, "Unexpected request after all configured replies were consumed.")
      replies.removeFirst()
      let body: String
      let statusCode: Int
      switch reply {
      case .response(let responseBody, let responseStatusCode):
        body = responseBody
        statusCode = responseStatusCode
      case .failure(let errorCode):
        throw URLError(errorCode)
      case .cancellation(let responseBody):
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
        body = responseBody
        statusCode = 200
      }
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
      return (Data(body.utf8), response)
    }
  }

  func makeLoader(transport: Transport) throws -> GmailBootstrapDiscovery {
    try GmailBootstrapDiscovery(client: GmailClient(tokenProvider: TokenProvider(), transport: transport), accountID: "account")
  }

  func makeCheckpoint(
    accountID: String = "account", position: GmailBootstrapCheckpoint.Position = .listing(pageToken: nil)
  ) throws -> GmailBootstrapCheckpoint {
    try GmailBootstrapCheckpoint(
      accountID: accountID, importGeneration: UUID(), policy: GmailSyncPolicy(version: 1),
      baselineHistoryId: "saved-baseline", position: position
    )
  }
}
