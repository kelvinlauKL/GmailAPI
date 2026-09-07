import Foundation
import Testing
import GmailAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GmailHistoryPageSequenceTests {
  @Test
  func fetchesOnlyWhenTheCallerRequestsAPage() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBodies: [#"{"historyId":"100","nextPageToken":"second"}"#])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let pages = GmailHistoryPageSequence(client: client, request: try GmailHistoryListRequest(startHistoryId: "90"))
    var iterator = pages.makeAsyncIterator()

    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.retrievalCount == 0)

    let page = try #require(try await iterator.next())

    #expect(page.historyId == "100")
    #expect(page.nextPageToken == "second")
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.retrievalCount == 1)
  }

  @Test
  func preservesTheBaselineAndFiltersDespiteNewerHistoryIDsAndEmptyPages() async throws {
    let transport = Transport(responseBodies: [
      #"{"history":[{"id":"91"}],"historyId":"100","nextPageToken":"next+/=%2F"}"#,
      #"{"history":[],"historyId":"200","nextPageToken":"last"}"#,
      #"{"history":[{"id":"210"}],"historyId":"300"}"#
    ])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let request = try GmailHistoryListRequest(
      startHistoryId: "00090", maxResults: 25, pageToken: "resume+/=%2F",
      labelId: "label+/", historyTypes: [.messageAdded, .labelRemoved]
    )
    var historyIDs: [String] = []
    var recordIDsByPage: [[String]?] = []

    for try await page in GmailHistoryPageSequence(client: client, request: request) {
      historyIDs.append(page.historyId)
      recordIDsByPage.append(page.history?.map(\.id))
    }

    #expect(historyIDs == ["100", "200", "300"])
    #expect(recordIDsByPage == [["91"], [], ["210"]])
    let requests = await transport.requests
    #expect(requests.count == 3)
    for (request, pageToken) in zip(requests, ["resume+/=%2F", "next+/=%2F", "last"]) {
      let url = try #require(request.url)
      #expect(url.path == "/gmail/v1/users/me/history")
      let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
      #expect(components.queryItems == [
        URLQueryItem(name: "startHistoryId", value: "00090"),
        URLQueryItem(name: "maxResults", value: "25"),
        URLQueryItem(name: "pageToken", value: pageToken),
        URLQueryItem(name: "labelId", value: "label+/"),
        URLQueryItem(name: "historyTypes", value: "messageAdded"),
        URLQueryItem(name: "historyTypes", value: "labelRemoved")
      ])
      #expect(components.percentEncodedQuery?.contains("+") == false)
    }
  }

  @Test(arguments: [
    #"{"historyId":"100"}"#, #"{"historyId":"100","history":[]}"#,
    #"{"historyId":"100","nextPageToken":null}"#, #"{"historyId":"100","nextPageToken":""}"#
  ])
  func yieldsTheFinalCursorEvenWithoutChangesAndStaysFinished(responseBody: String) async throws {
    let transport = Transport(responseBodies: [responseBody])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    var iterator = GmailHistoryPageSequence(
      client: client, request: try GmailHistoryListRequest(startHistoryId: "90")
    ).makeAsyncIterator()

    #expect(try await iterator.next()?.historyId == "100")
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
    #expect(await transport.requests.count == 1)
  }

  @Test
  func stoppingConsumptionDoesNotFetchAnotherPage() async throws {
    let transport = Transport(responseBodies: [#"{"historyId":"100","nextPageToken":"second"}"#])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let pages = GmailHistoryPageSequence(client: client, request: try GmailHistoryListRequest(startHistoryId: "90"))

    for try await _ in pages { break }

    #expect(await transport.requests.count == 1)
  }

  @Test
  func iteratorsHaveIndependentPaginationState() async throws {
    let transport = Transport(responseBodies: [#"{"historyId":"100","nextPageToken":"second"}"#])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let pages = GmailHistoryPageSequence(client: client, request: try GmailHistoryListRequest(startHistoryId: "90"))
    var firstIterator = pages.makeAsyncIterator()
    var secondIterator = pages.makeAsyncIterator()

    _ = try await firstIterator.next()
    _ = try await firstIterator.next()
    _ = try await secondIterator.next()

    let tokens = await transport.requests.map { request in
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "pageToken" }?.value
    }
    #expect(tokens == [nil, "second", nil])
  }

  @Test(arguments: [
    (String?.none, ["first", "first"]), (nil, ["first", "second", "first"]), ("first", ["first"])
  ])
  func rejectsTokenCyclesBeforeSendingADuplicateRequest(startingToken: String?, continuationTokens: [String]) async throws {
    let transport = Transport(responseBodies: continuationTokens.map { pageToken in
      #"{"historyId":"100","nextPageToken":"\#(pageToken)"}"#
    })
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    var iterator = GmailHistoryPageSequence(
      client: client, request: try GmailHistoryListRequest(startHistoryId: "90", pageToken: startingToken)
    ).makeAsyncIterator()

    for _ in continuationTokens { #expect(try await iterator.next() != nil) }
    await #expect(throws: GmailHistoryPageSequence.PaginationError.repeatedPageToken) {
      try await iterator.next()
    }
    #expect(try await iterator.next() == nil)
    #expect(await transport.requests.count == continuationTokens.count)
  }

  @Test(arguments: [404, 503])
  func preservesHistoryFailuresAfterEarlierPagesAndFinishes(statusCode: Int) async throws {
    let transport = Transport(
      responseBodies: [#"{"historyId":"100","nextPageToken":"second"}"#, "{}"], statusCodes: [200, statusCode]
    )
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    var iterator = GmailHistoryPageSequence(
      client: client, request: try GmailHistoryListRequest(startHistoryId: "90")
    ).makeAsyncIterator()
    let expectedFailure = GmailRequestFailure(statusCode: statusCode, context: .historyList)

    #expect(try await iterator.next()?.historyId == "100")
    await #expect(throws: GmailClient.RequestError.requestFailed(expectedFailure)) {
      try await iterator.next()
    }
    #expect(try await iterator.next() == nil)
    #expect(await transport.requests.count == 2)
  }

  @Test
  func preservesTransportErrorsAndFinishes() async throws {
    let transport = Transport(responseBodies: ["{}"], error: URLError(.timedOut))
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    var iterator = GmailHistoryPageSequence(
      client: client, request: try GmailHistoryListRequest(startHistoryId: "90")
    ).makeAsyncIterator()

    do {
      _ = try await iterator.next()
      Issue.record("Expected a transport failure.")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    }
    #expect(try await iterator.next() == nil)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: ["not json", "{}", #"{"historyId":null}"#])
  func malformedResponsesFinishIteration(responseBody: String) async throws {
    let transport = Transport(responseBodies: [responseBody])
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    var iterator = GmailHistoryPageSequence(
      client: client, request: try GmailHistoryListRequest(startHistoryId: "90")
    ).makeAsyncIterator()

    await #expect(throws: GmailClient.RequestError.invalidResponse) { try await iterator.next() }
    #expect(try await iterator.next() == nil)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: CancellationStage.allCases)
  func cancellationFinishesTheIterator(stage: CancellationStage) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(
      responseBodies: [#"{"historyId":"100","nextPageToken":"second"}"#], cancelsTask: stage == .duringRequest
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let pages = GmailHistoryPageSequence(client: client, request: try GmailHistoryListRequest(startHistoryId: "90"))
    let requestTask = Task {
      var iterator = pages.makeAsyncIterator()
      if stage == .betweenPages { _ = try await iterator.next() }
      if stage != .duringRequest { withUnsafeCurrentTask { currentTask in currentTask?.cancel() } }
      await #expect(throws: CancellationError.self) { try await iterator.next() }
      #expect(try await iterator.next() == nil)
    }

    try await requestTask.value
    #expect(await transport.requests.count == (stage == .beforeFirstPage ? 0 : 1))
    #expect(await tokenProvider.retrievalCount == (stage == .beforeFirstPage ? 0 : 1))
  }

  @Test
  func providesPaginationRecoveryGuidance() throws {
    let error = GmailHistoryPageSequence.PaginationError.repeatedPageToken

    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}

extension GmailHistoryPageSequenceTests {
  enum CancellationStage: CaseIterable, Sendable {
    case beforeFirstPage, duringRequest, betweenPages
  }
}

private extension GmailHistoryPageSequenceTests {
  actor TokenProvider: GmailTokenProvider {
    private(set) var retrievalCount = 0

    func accessToken() async throws -> String {
      retrievalCount += 1
      return "test-token"
    }

    func invalidate(rejectedAccessToken: String) async throws {}
  }

  actor Transport: GmailTransport {
    private let responseBodies: [String]
    private let statusCodes: [Int]
    private let error: (any Error)?
    private let cancelsTask: Bool
    private(set) var requests: [URLRequest] = []

    init(responseBodies: [String], statusCodes: [Int] = [200], error: (any Error)? = nil, cancelsTask: Bool = false) {
      self.responseBodies = responseBodies
      self.statusCodes = statusCodes
      self.error = error
      self.cancelsTask = cancelsTask
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      requests.append(request)
      if let error { throw error }
      if cancelsTask { withUnsafeCurrentTask { currentTask in currentTask?.cancel() } }
      let requestIndex = requests.count - 1
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: statusCodes[min(requestIndex, statusCodes.count - 1)],
        httpVersion: nil, headerFields: nil
      ))
      return (Data(responseBodies[min(requestIndex, responseBodies.count - 1)].utf8), response)
    }
  }
}
