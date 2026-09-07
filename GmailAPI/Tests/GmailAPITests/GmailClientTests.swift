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
      #expect(error == .requestFailed(GmailRequestFailure(statusCode: statusCode)))
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

  @Test(arguments: [
    (["userRateLimitExceeded"], GmailRequestFailure.Category.rateLimited, true),
    (["dailyLimitExceeded"], .quotaExceeded, false),
    (["userRateLimitExceeded", "domainPolicy"], .forbidden, false)
  ])
  func exposesClassifiedDiagnosticsWithoutRetrying(
    reasons: [String], expectedCategory: GmailRequestFailure.Category, expectedRetryability: Bool
  ) async throws {
    let privateContent = "private-response-content"
    let responseData = try JSONSerialization.data(withJSONObject: [
      "error": [
        "code": 500, "message": privateContent,
        "errors": reasons.map { ["reason": $0, "message": privateContent] }
      ]
    ])
    let tokenProvider = TokenProvider()
    let transport = Transport(
      statusCodes: [403, 200], responseBody: String(decoding: responseData, as: UTF8.self),
      responseHeaders: ["retry-after": "120"]
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    do {
      _ = try await client.profile()
      Issue.record("Expected a classified HTTP failure.")
    } catch GmailClient.RequestError.requestFailed(let failure) {
      #expect(failure.statusCode == 403)
      #expect(failure.details?.code == 500)
      #expect(failure.details?.message == privateContent)
      #expect(failure.details?.errors?.map(\.reason) == reasons)
      #expect(failure.retryAfter == "120")
      #expect(failure.context == .general)
      #expect(failure.category == expectedCategory)
      #expect(failure.isRetryable == expectedRetryability)
      let error = GmailClient.RequestError.requestFailed(failure)
      #expect(error.localizedDescription == failure.localizedDescription)
      #expect(error.failureReason == failure.failureReason)
      #expect(error.recoverySuggestion == failure.recoverySuggestion)
      #expect(!error.localizedDescription.contains(privateContent))
      #expect(error.failureReason?.contains(privateContent) == false)
      #expect(error.recoverySuggestion?.contains(privateContent) == false)
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func preservesExpiredHistoryContextAcrossAuthenticationRetry() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(
      statusCodes: [401, 404, 200], responseBody: #"{"error":{"code":404}}"#,
      responseHeaders: ["Retry-After": "60"]
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90", pageToken: "page+/=%2F")

    do {
      _ = try await client.listHistory(options)
      Issue.record("Expected an expired history failure.")
    } catch GmailClient.RequestError.requestFailed(let failure) {
      #expect(failure.statusCode == 404)
      #expect(failure.details?.code == 404)
      #expect(failure.context == .historyList)
      #expect(failure.category == .historyExpired)
      #expect(!failure.isRetryable)
      #expect(failure.retryAfter == "60")
    }
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test(arguments: [
    "<html>Unavailable</html>", "{}", #"{"error":null}"#,
    #"{"error":{"code":"403"}}"#,
    #"{"error":{"code":403,"errors":[{"reason":null}]}}"#
  ])
  func preservesStatusAndRetryHeaderWhenErrorDiagnosticsAreUnreadable(responseBody: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(
      statusCodes: [403], responseBody: responseBody,
      responseHeaders: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    do {
      _ = try await client.profile()
      Issue.record("Expected an HTTP failure with unavailable diagnostics.")
    } catch GmailClient.RequestError.requestFailed(let failure) {
      #expect(failure.statusCode == 403)
      #expect(failure.details == nil)
      #expect(failure.retryAfter == "Wed, 21 Oct 2015 07:28:00 GMT")
      #expect(failure.category == .forbidden)
      #expect(!failure.isRetryable)
    }
    #expect(await transport.requests.count == 1)
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

  @Test
  func listsOneAuthenticatedPageWithDefaultOptions() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: """
      {
        "threads":[{"id":"thread-1","snippet":"Preview","historyId":"123"},{"id":"thread-2"}],
        "nextPageToken":"next-page", "resultSizeEstimate":42
      }
      """)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailThreadListRequest()

    let page = try await client.listThreads(options)

    #expect(page.threads?.map(\.id) == ["thread-1", "thread-2"])
    #expect(page.threads?.first?.snippet == "Preview")
    #expect(page.threads?.first?.historyId == "123")
    #expect(page.nextPageToken == "next-page")
    #expect(page.resultSizeEstimate == 42)
    let requests = await transport.requests
    let request = try #require(requests.first)
    let url = try #require(request.url)
    #expect(requests.count == 1)
    #expect(url.scheme == "https")
    #expect(url.host == "gmail.googleapis.com")
    #expect(url.path == "/gmail/v1/users/me/threads")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(try decodedQueryItems(in: url) == [
      URLQueryItem(name: "maxResults", value: "100"),
      URLQueryItem(name: "includeSpamTrash", value: "false")
    ])
  }

  @Test
  func preservesThreadFiltersAndPageTokenAcrossAuthenticationRetry() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(statusCodes: [401, 200], responseBody: "{}")
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let query = #"from:alice+tag@example.com subject:"A&B #1" 雪 %2B"#
    let pageToken = "page+/=%2F&next=2#雪"
    let labelIDs = ["INBOX", "Label_+/%2F&?="]
    let options = try GmailThreadListRequest(
      q: query, maxResults: 250, pageToken: pageToken,
      labelIds: labelIDs, includeSpamTrash: true
    )

    _ = try await client.listThreads(options)

    let requests = await transport.requests
    let url = try #require(requests.first?.url)
    let urlComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let encodedQuery = try #require(urlComponents.percentEncodedQuery)
    #expect(!encodedQuery.contains("+"))
    #expect(encodedQuery.contains("%2B"))
    #expect(try decodedQueryItems(in: url) == [
      URLQueryItem(name: "maxResults", value: "250"),
      URLQueryItem(name: "includeSpamTrash", value: "true"),
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "pageToken", value: pageToken),
      URLQueryItem(name: "labelIds", value: labelIDs[0]),
      URLQueryItem(name: "labelIds", value: labelIDs[1])
    ])
    #expect(requests.count == 2)
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test
  func fetchesNextThreadPageOnlyWhenRequested() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: #"{"threads":[{"id":"first"}],"nextPageToken":"next+/=%2F"}"#)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let firstOptions = try GmailThreadListRequest(q: "is:unread")

    let firstPage = try await client.listThreads(firstOptions)

    #expect(await transport.requests.count == 1)
    let nextPageToken = try #require(firstPage.nextPageToken)
    await transport.setResponseBody(#"{"threads":[{"id":"second"}]}"#)
    let nextOptions = try GmailThreadListRequest(q: "is:unread", pageToken: nextPageToken)
    let secondPage = try await client.listThreads(nextOptions)

    #expect(firstPage.threads?.map(\.id) == ["first"])
    #expect(secondPage.threads?.map(\.id) == ["second"])
    #expect(secondPage.nextPageToken == nil)
    let requests = await transport.requests
    let nextURL = try #require(requests.last?.url)
    let queryItems = try decodedQueryItems(in: nextURL)
    #expect(queryItems.contains(URLQueryItem(name: "pageToken", value: "next+/=%2F")))
    #expect(queryItems.contains(URLQueryItem(name: "q", value: "is:unread")))
    #expect(requests.count == 2)
  }

  @Test(arguments: ["{}", #"{"threads":[],"resultSizeEstimate":0}"#, #"{"threads":null,"nextPageToken":null}"#])
  func acceptsEmptyThreadPages(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let options = try GmailThreadListRequest()

    let page = try await client.listThreads(options)

    #expect(page.threads?.isEmpty ?? true)
    #expect(page.nextPageToken == nil)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: ["not json", #"{"threads":{}}"#, #"{"nextPageToken":123}"#])
  func rejectsMalformedThreadPagesWithoutRetry(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let options = try GmailThreadListRequest()

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await client.listThreads(options)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [403, 429])
  func preservesThreadListingHTTPFailures(statusCode: Int) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(statusCodes: [statusCode], responseBody: "{}")
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailThreadListRequest()

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: statusCode))) {
      try await client.listThreads(options)
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func listsOneAuthenticatedHistoryPageWithDefaultOptions() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: """
      {
        "history":[
          {"id":"100","messagesAdded":[{"message":{"id":"message-1","threadId":"thread-1"}}]},
          {"id":"104","labelsRemoved":[{
            "message":{"id":"message-2","threadId":"thread-2"},"labelIds":["UNREAD"]
          }]}
        ],
        "nextPageToken":"next-page",
        "historyId":"18446744073709551615"
      }
      """)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90")

    let page = try await client.listHistory(options)

    #expect(page.history?.map(\.id) == ["100", "104"])
    #expect(page.history?.first?.messagesAdded?.first?.message.id == "message-1")
    #expect(page.history?.last?.labelsRemoved?.first?.labelIds == ["UNREAD"])
    #expect(page.nextPageToken == "next-page")
    #expect(page.historyId == "18446744073709551615")
    let requests = await transport.requests
    let request = try #require(requests.first)
    let url = try #require(request.url)
    #expect(requests.count == 1)
    #expect(url.scheme == "https")
    #expect(url.host == "gmail.googleapis.com")
    #expect(url.path == "/gmail/v1/users/me/history")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(try decodedQueryItems(in: url) == [
      URLQueryItem(name: "startHistoryId", value: "90"),
      URLQueryItem(name: "maxResults", value: "100")
    ])
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func preservesHistoryFiltersAndPageTokenAcrossAuthenticationRetry() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(statusCodes: [401, 200], responseBody: #"{"historyId":"200"}"#)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let startHistoryId = "123+/=%2F&next=2#雪"
    let pageToken = "page+/=%2F&next=2#雪"
    let labelId = "Label_+/%2F&?= 雪"
    let options = try GmailHistoryListRequest(
      startHistoryId: startHistoryId, maxResults: 250, pageToken: pageToken,
      labelId: labelId, historyTypes: [.labelRemoved, .messageAdded, .messageDeleted, .labelAdded]
    )

    let page = try await client.listHistory(options)

    #expect(page.historyId == "200")
    let requests = await transport.requests
    let url = try #require(requests.first?.url)
    let urlComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let encodedQuery = try #require(urlComponents.percentEncodedQuery)
    #expect(url.path == "/gmail/v1/users/me/history")
    #expect(url.fragment == nil)
    #expect(!encodedQuery.contains("+"))
    #expect(encodedQuery.contains("%2B"))
    #expect(try decodedQueryItems(in: url) == [
      URLQueryItem(name: "startHistoryId", value: startHistoryId),
      URLQueryItem(name: "maxResults", value: "250"),
      URLQueryItem(name: "pageToken", value: pageToken),
      URLQueryItem(name: "labelId", value: labelId),
      URLQueryItem(name: "historyTypes", value: "labelRemoved"),
      URLQueryItem(name: "historyTypes", value: "messageAdded"),
      URLQueryItem(name: "historyTypes", value: "messageDeleted"),
      URLQueryItem(name: "historyTypes", value: "labelAdded")
    ])
    #expect(requests.count == 2)
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test
  func fetchesNextHistoryPageOnlyWhenRequested() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: #"{"historyId":"200","nextPageToken":"next+/=%2F"}"#)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let firstOptions = try GmailHistoryListRequest(
      startHistoryId: "90", maxResults: 250, labelId: "INBOX", historyTypes: [.messageAdded]
    )

    let firstPage = try await client.listHistory(firstOptions)

    #expect(firstPage.history == nil)
    #expect(firstPage.historyId == "200")
    #expect(await transport.requests.count == 1)
    let nextPageToken = try #require(firstPage.nextPageToken)
    await transport.setResponseBody(#"{"history":[{"id":"100"}],"historyId":"200"}"#)
    let nextOptions = try GmailHistoryListRequest(
      startHistoryId: "90", maxResults: 250, pageToken: nextPageToken,
      labelId: "INBOX", historyTypes: [.messageAdded]
    )
    let secondPage = try await client.listHistory(nextOptions)

    #expect(secondPage.history?.map(\.id) == ["100"])
    #expect(secondPage.historyId == "200")
    #expect(secondPage.nextPageToken == nil)
    let requests = await transport.requests
    let nextURL = try #require(requests.last?.url)
    #expect(try decodedQueryItems(in: nextURL) == [
      URLQueryItem(name: "startHistoryId", value: "90"),
      URLQueryItem(name: "maxResults", value: "250"),
      URLQueryItem(name: "pageToken", value: "next+/=%2F"),
      URLQueryItem(name: "labelId", value: "INBOX"),
      URLQueryItem(name: "historyTypes", value: "messageAdded")
    ])
    #expect(requests.count == 2)
  }

  @Test(arguments: [
    #"{"historyId":"200"}"#,
    #"{"history":[],"historyId":"200"}"#,
    #"{"history":null,"nextPageToken":null,"historyId":"200"}"#
  ])
  func acceptsEmptyHistoryPages(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90")

    let page = try await client.listHistory(options)

    #expect(page.history?.isEmpty ?? true)
    #expect(page.historyId == "200")
    #expect(page.nextPageToken == nil)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [
    "not json", "{}", #"{"historyId":null}"#, #"{"historyId":200}"#,
    #"{"history":{},"historyId":"200"}"#,
    #"{"history":[{}],"historyId":"200"}"#,
    #"{"nextPageToken":123,"historyId":"200"}"#
  ])
  func rejectsMalformedHistoryPagesWithoutRetry(responseBody: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90")

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await client.listHistory(options)
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: [403, 404, 429, 503])
  func preservesHistoryListingHTTPFailuresWithoutRetry(statusCode: Int) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(statusCodes: [statusCode], responseBody: "unreadable error response")
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90")

    let expectedFailure = GmailRequestFailure(statusCode: statusCode, context: .historyList)
    await #expect(throws: GmailClient.RequestError.requestFailed(expectedFailure)) {
      try await client.listHistory(options)
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func fetchesAndDecodesAuthenticatedFullThread() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: """
      {
        "id":"thread-1", "historyId":"123", "snippet":"Hello",
        "messages":[
          {"id":"message-1","threadId":"thread-1",
           "payload":{"mimeType":"text/plain","body":{"size":5,"data":"SGVsbG8="}}},
          {"id":"message-2","threadId":"thread-1"}
        ]
      }
      """)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    let thread = try await client.thread(id: "thread-1")

    #expect(thread.id == "thread-1")
    #expect(thread.historyId == "123")
    #expect(thread.snippet == "Hello")
    #expect(thread.messages.map(\.id) == ["message-1", "message-2"])
    #expect(thread.messages.first?.payload?.body?.data == "SGVsbG8=")
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/threads/thread-1?format=full")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: [
    "a/b", "../profile", #"..\profile"#, "%2E%2E", "https://other.example/path",
    "thread+/%2F?format=minimal&userId=other#雪 space"
  ])
  func encodesThreadIDAsSinglePathSegment(threadID: String) async throws {
    let transport = Transport(responseBody: #"{"id":"thread-1","messages":[]}"#)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)

    _ = try await client.thread(id: threadID)

    let requests = await transport.requests
    let url = try #require(requests.first?.url)
    let urlComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let threadPathPrefix = "/gmail/v1/users/me/threads/"
    let encodedThreadID = String(urlComponents.percentEncodedPath.dropFirst(threadPathPrefix.count))
    #expect(urlComponents.scheme == "https")
    #expect(urlComponents.host == "gmail.googleapis.com")
    #expect(urlComponents.percentEncodedPath.hasPrefix(threadPathPrefix))
    #expect(!encodedThreadID.contains("/"))
    #expect(encodedThreadID.removingPercentEncoding == threadID)
    #expect(urlComponents.fragment == nil)
    #expect(urlComponents.queryItems == [URLQueryItem(name: "format", value: "full")])
    #expect(requests.count == 1)
  }

  @Test(arguments: ["", ".", ".."])
  func rejectsInvalidThreadIDsBeforeRequestingCredentials(threadID: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidThreadID) {
      try await client.thread(id: threadID)
    }
    #expect(await tokenProvider.retrievalCount == 0)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
    #expect(await transport.requests.isEmpty)
  }

  @Test
  func preservesFullThreadRequestAcrossAuthenticationRetry() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(statusCodes: [401, 200], responseBody: #"{"id":"thread-1","messages":[]}"#)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    #expect(try await client.thread(id: "thread-1").id == "thread-1")

    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.first?.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/threads/thread-1?format=full")
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test(arguments: [403, 404, 429, 500])
  func preservesThreadFetchHTTPFailuresWithoutRetry(statusCode: Int) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(statusCodes: [statusCode], responseBody: "{}")
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: statusCode))) {
      try await client.thread(id: "thread-1")
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: [
    "not json", "{}", #"{"id":"thread-1"}"#,
    #"{"id":"thread-1","messages":null}"#,
    #"{"id":"thread-1","messages":[{"threadId":"thread-1"}]}"#
  ])
  func rejectsMalformedThreadsWithoutRetry(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await client.thread(id: "thread-1")
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [
    #"{"size":2,"data":"-_8=","futureField":true}"#,
    #"{"size":2,"data":"-_8"}"#,
    #"{"data":"-_8"}"#,
    #"{"size":null,"data":"-_8"}"#
  ])
  func fetchesAndDecodesAuthenticatedAttachment(responseBody: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    let content = try await client.attachment(messageID: "message-1", attachmentID: "attachment-1")

    #expect(content == Data([0xfb, 0xff]))
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1/attachments/attachment-1")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func encodesMessageAndAttachmentIDsAsSeparatePathSegments() async throws {
    let transport = Transport(responseBody: #"{"size":0,"data":""}"#)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)
    let messageID = "../message%2F?alt=media#雪"
    let attachmentID = "attachment+/%2E%2E?userId=other#雪 space"

    _ = try await client.attachment(messageID: messageID, attachmentID: attachmentID)

    let requests = await transport.requests
    let url = try #require(requests.first?.url)
    let urlComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let pathSegments = urlComponents.percentEncodedPath.split(separator: "/").map {
      String($0).removingPercentEncoding
    }
    #expect(pathSegments == ["gmail", "v1", "users", "me", "messages", messageID, "attachments", attachmentID])
    #expect(urlComponents.scheme == "https")
    #expect(urlComponents.host == "gmail.googleapis.com")
    #expect(urlComponents.query == nil)
    #expect(urlComponents.fragment == nil)
    #expect(requests.count == 1)
  }

  @Test(arguments: ["", ".", ".."])
  func rejectsInvalidAttachmentRequestIDsBeforeRequestingCredentials(invalidID: String) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidMessageID) {
      try await client.attachment(messageID: invalidID, attachmentID: "attachment-1")
    }
    await #expect(throws: GmailClient.RequestError.invalidAttachmentID) {
      try await client.attachment(messageID: "message-1", attachmentID: invalidID)
    }
    #expect(await tokenProvider.retrievalCount == 0)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: [#"{"size":0,"data":""}"#, #"{"data":""}"#])
  func acceptsExplicitEmptyAttachmentContent(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)

    let content = try await client.attachment(messageID: "message-1", attachmentID: "attachment-1")

    #expect(content.isEmpty)
    #expect(await transport.requests.count == 1)
  }

  @Test
  func preservesAttachmentRequestAcrossAuthenticationRetry() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-token", "replacement-token"])
    let transport = Transport(statusCodes: [401, 200], responseBody: #"{"size":5,"data":"SGVsbG8"}"#)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    let content = try await client.attachment(messageID: "message-1", attachmentID: "attachment-1")

    #expect(content == Data("Hello".utf8))
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.first?.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1/attachments/attachment-1")
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-token", "Bearer replacement-token"
    ])
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-token"])
  }

  @Test(arguments: [403, 404, 429, 503])
  func preservesAttachmentHTTPFailuresWithoutRetry(statusCode: Int) async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(statusCodes: [statusCode], responseBody: "{}")
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: statusCode))) {
      try await client.attachment(messageID: "message-1", attachmentID: "attachment-1")
    }
    #expect(await transport.requests.count == 1)
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test(arguments: [
    "not json", "{}", #"{"size":0}"#,
    #"{"size":2,"data":null}"#, #"{"size":2,"data":123}"#,
    #"{"size":2,"data":"===="}"#, #"{"size":2,"data":"A"}"#,
    #"{"size":3,"data":"-_8"}"#, #"{"size":-1,"data":""}"#,
    #"{"size":"2","data":"-_8"}"#, #"{"size":2,"data":""}"#
  ])
  func rejectsIncompleteOrMalformedAttachmentsWithoutRetry(responseBody: String) async throws {
    let transport = Transport(responseBody: responseBody)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport)

    await #expect(throws: GmailClient.RequestError.invalidResponse) {
      try await client.attachment(messageID: "message-1", attachmentID: "attachment-1")
    }
    #expect(await transport.requests.count == 1)
  }

  @Test
  func finalRejectionRemainsAuthenticationErrorWhenInvalidationIsCancelled() async throws {
    let tokenProvider = TokenProvider(cancellationStage: .invalidation, cancellationInvalidationCount: 2)
    let transport = Transport(statusCodes: [401, 401, 200])
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let requestTask = Task { try await client.profile() }

    await #expect(throws: GmailClient.RequestError.reauthorizationRequired) {
      try await requestTask.value
    }
    #expect(await transport.requests.count == 2)
    #expect(await tokenProvider.invalidatedTokens.count == 2)
  }

  @Test(arguments: [429, 500, 502, 503, 504])
  func retriesHTTPFailuresWhenThePolicyAllowsIt(statusCode: Int) async throws {
    let tokenProvider = TokenProvider(tokens: ["first-token", "second-token"])
    let transport = Transport(statusCodes: [statusCode, 200])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)

    #expect(try await client.profile().emailAddress == "demo@example.com")

    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.first?.url == requests.last?.url)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer first-token", "Bearer second-token"
    ])
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Accept") == "application/json" })
    #expect(await retryPolicy.failures == [GmailRequestFailure(statusCode: statusCode)])
    #expect(await retryPolicy.retryCounts == [0])
    #expect(await tokenProvider.invalidatedTokens.isEmpty)
  }

  @Test
  func preservesTheFinalFailureWhenTheRetryBudgetIsExhausted() async throws {
    let responseBody = #"{"error":{"code":503,"errors":[{"reason":"backendError"}]}}"#
    let details = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(responseBody.utf8)).error
    let transport = Transport(
      statusCodes: [429, 502, 503, 200], responseBody: responseBody,
      responseHeaders: ["Retry-After": "12"]
    )
    let retryPolicy = RetryPolicy(maximumRetries: 2)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)
    let expectedFailure = GmailRequestFailure(statusCode: 503, details: details, retryAfter: "12")

    await #expect(throws: GmailClient.RequestError.requestFailed(expectedFailure)) {
      try await client.profile()
    }

    #expect(await transport.requests.count == 3)
    #expect(await retryPolicy.retryCounts == [0, 1, 2])
    #expect(await retryPolicy.failures.map(\.statusCode) == [429, 502, 503])
    #expect(await retryPolicy.failures.last == expectedFailure)
  }

  @Test
  func preservesHistoryOptionsAndRetryCountsAcrossAuthenticationRefresh() async throws {
    let tokenProvider = TokenProvider(tokens: ["first", "rejected", "third", "fourth"])
    let transport = Transport(statusCodes: [503, 401, 503, 200], responseBody: #"{"historyId":"100"}"#)
    let retryPolicy = RetryPolicy(maximumRetries: 2)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)
    let options = try GmailHistoryListRequest(
      startHistoryId: "90", maxResults: 25, pageToken: "page+/=%2F", labelId: "INBOX", historyTypes: [.messageAdded]
    )

    #expect(try await client.listHistory(options).historyId == "100")

    let requests = await transport.requests
    let requestURL = try #require(requests.first?.url)
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.url == requestURL })
    #expect(try decodedQueryItems(in: requestURL) == [
      URLQueryItem(name: "startHistoryId", value: "90"),
      URLQueryItem(name: "maxResults", value: "25"),
      URLQueryItem(name: "pageToken", value: "page+/=%2F"),
      URLQueryItem(name: "labelId", value: "INBOX"),
      URLQueryItem(name: "historyTypes", value: "messageAdded")
    ])
    #expect(await retryPolicy.retryCounts == [0, 1])
    #expect(await retryPolicy.failures == Array(repeating: GmailRequestFailure(statusCode: 503, context: .historyList), count: 2))
    #expect(await tokenProvider.invalidatedTokens == ["rejected"])
    #expect(await tokenProvider.retrievalCount == 4)
  }

  @Test(arguments: [true, false])
  func transientRetriesDoNotResetTheAuthenticationRetryLimit(failsInTransport: Bool) async throws {
    let tokenProvider = TokenProvider(tokens: ["first", "second", "third"])
    let transport = Transport(
      statusCodes: [401, 503, 401, 200], errorsByRequestNumber: failsInTransport ? [2: URLError(.timedOut)] : [:]
    )
    let retryPolicy = RetryPolicy(maximumRetries: 2)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: GmailClient.RequestError.reauthorizationRequired) {
      try await client.profile()
    }

    #expect(await transport.requests.count == 3)
    #expect(await tokenProvider.invalidatedTokens == ["first", "third"])
    #expect(await retryPolicy.retryCounts == [0])
  }

  @Test
  func passesTheOriginalTransportErrorToThePolicy() async throws {
    let transportError = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "test timeout"])
    let transport = Transport(errorsByRequestNumber: [1: transportError])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)

    #expect(try await client.profile().emailAddress == "demo@example.com")

    let receivedError = try #require(await retryPolicy.transportErrors.first as? URLError)
    #expect(receivedError.code == .timedOut)
    #expect(receivedError.localizedDescription == "test timeout")
    #expect(await transport.requests.count == 2)
    #expect(await retryPolicy.retryCounts == [0])
  }

  @Test
  func sharesOneBudgetBetweenTransportAndHTTPFailures() async throws {
    let transport = Transport(statusCodes: [200, 503, 200], errorsByRequestNumber: [1: URLError(.timedOut)])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: 503))) {
      try await client.profile()
    }

    #expect(await transport.requests.count == 2)
    #expect(await retryPolicy.retryCounts == [0, 1])
  }

  @Test
  func preservesTheTransportErrorWhenThePolicyDeclines() async throws {
    let transport = Transport(errorsByRequestNumber: [1: URLError(.serverCertificateUntrusted)])
    let client = GmailClient(
      tokenProvider: TokenProvider(), transport: transport, retryPolicy: ExponentialGmailRetryPolicy()
    )

    do {
      _ = try await client.profile()
      Issue.record("Expected the original transport error.")
    } catch let error as URLError {
      #expect(error.code == .serverCertificateUntrusted)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [403, 404, 501])
  func theExponentialPolicyDeclinesPermanentFailures(statusCode: Int) async throws {
    let transport = Transport(statusCodes: [statusCode, 200])
    let client = GmailClient(
      tokenProvider: TokenProvider(), transport: transport, retryPolicy: ExponentialGmailRetryPolicy()
    )

    await #expect(throws: GmailClient.RequestError.requestFailed(GmailRequestFailure(statusCode: statusCode))) {
      try await client.profile()
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [DependencyFailure.credentials, .invalidation])
  func doesNotPassProviderErrorsToTheRetryPolicy(failure: DependencyFailure) async throws {
    let tokenProvider = TokenProvider(failure: failure)
    let transport = Transport(statusCodes: [401])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: failure) { try await client.profile() }

    #expect(await retryPolicy.retryCounts.isEmpty)
    #expect(await tokenProvider.retrievalCount == 1)
  }

  @Test
  func doesNotRetryInvalidSuccessfulResponses() async throws {
    let transport = Transport(responseBody: "{}")
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: GmailClient.RequestError.invalidResponse) { try await client.profile() }

    #expect(await retryPolicy.retryCounts.isEmpty)
    #expect(await transport.requests.count == 1)
  }

  @Test
  func validatesCredentialsAgainAfterAWait() async throws {
    let tokenProvider = TokenProvider(tokens: ["first-token", "invalid token"])
    let transport = Transport(statusCodes: [503, 200])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: GmailClient.RequestError.invalidAccessToken) { try await client.profile() }

    #expect(await retryPolicy.retryCounts == [0])
    #expect(await tokenProvider.retrievalCount == 2)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [true, false])
  func propagatesTransportCancellationWithoutConsultingThePolicy(usesURLError: Bool) async throws {
    let cancellation: any Error = usesURLError ? URLError(.cancelled) : CancellationError()
    let transport = Transport(errorsByRequestNumber: [1: cancellation])
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)

    do {
      _ = try await client.profile()
      Issue.record("Expected transport cancellation.")
    } catch {
      #expect(usesURLError ? (error as? URLError)?.code == .cancelled : error is CancellationError)
    }
    #expect(await retryPolicy.retryCounts.isEmpty)
    #expect(await transport.requests.count == 1)
  }

  @Test
  func cancellationDuringTheRetryWaitPreventsAnotherCredentialRequest() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(statusCodes: [503, 200])
    let retryPolicy = RetryPolicy(cancelsTask: true)
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)
    let requestTask = Task { try await client.profile() }

    await #expect(throws: CancellationError.self) { try await requestTask.value }

    #expect(await retryPolicy.retryCounts == [0])
    #expect(await tokenProvider.retrievalCount == 1)
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [true, false])
  func propagatesRetryPolicyErrors(failsInTransport: Bool) async throws {
    let transport = Transport(
      statusCodes: [503], errorsByRequestNumber: failsInTransport ? [1: URLError(.timedOut)] : [:]
    )
    let retryPolicy = RetryPolicy(failure: DependencyFailure.transport)
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)

    await #expect(throws: DependencyFailure.transport) { try await client.profile() }

    #expect(await retryPolicy.retryCounts == [0])
    #expect(await transport.requests.count == 1)
  }

  @Test
  func concurrentOperationsHaveIndependentRetryBudgets() async throws {
    let transport = RetryingTransport()
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: TokenProvider(), transport: transport, retryPolicy: retryPolicy)
    let options = try GmailThreadListRequest()

    async let profile = client.profile()
    async let threads = client.listThreads(options)
    let responses = try await (profile, threads)

    #expect(responses.0.emailAddress == "demo@example.com")
    #expect(responses.1.threads == [])
    #expect(await retryPolicy.retryCounts == [0, 0])
    #expect(await transport.requestCounts.count == 2)
    #expect(await transport.requestCounts.values.allSatisfy { $0 == 2 })
  }

  @Test
  func threadPagesUseTheClientsDependenciesAndAFreshRetryBudgetForEachPage() async throws {
    let tokenProvider = TokenProvider()
    let transport = Transport(
      statusCodes: [503, 200, 503, 200],
      responseBody: #"{"threads":[{"id":"first"}],"nextPageToken":"second+/=%2F"}"#
    )
    let retryPolicy = RetryPolicy()
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport, retryPolicy: retryPolicy)
    let options = try GmailThreadListRequest(q: "from:demo+tag@example.com", pageToken: "resume")
    let pages: GmailThreadPageSequence = client.threadPages(options)

    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.retrievalCount == 0)
    var threadIDs: [String] = []
    for try await page in pages {
      threadIDs.append(contentsOf: page.threads?.map(\.id) ?? [])
      await transport.setResponseBody(#"{"threads":[{"id":"second"}]}"#)
    }

    #expect(threadIDs == ["first", "second"])
    #expect(await retryPolicy.retryCounts == [0, 0])
    #expect(await tokenProvider.retrievalCount == 4)
    let requests = await transport.requests
    #expect(requests.count == 4)
    for (request, pageToken) in zip(requests, ["resume", "resume", "second+/=%2F", "second+/=%2F"]) {
      let url = try #require(request.url)
      #expect(url.path == "/gmail/v1/users/me/threads")
      let queryItems = try decodedQueryItems(in: url)
      #expect(queryItems.contains(URLQueryItem(name: "q", value: "from:demo+tag@example.com")))
      #expect(queryItems.contains(URLQueryItem(name: "pageToken", value: pageToken)))
    }
  }

  @Test
  func historyPagesPreserveTheCursorAcrossAuthenticationRetriesOnEachPage() async throws {
    let tokenProvider = TokenProvider(tokens: ["rejected-first", "valid-first", "rejected-second", "valid-second"])
    let transport = Transport(
      statusCodes: [401, 200, 401, 200],
      responseBody: #"{"historyId":"100","nextPageToken":"second+/=%2F"}"#
    )
    let client = GmailClient(tokenProvider: tokenProvider, transport: transport)
    let options = try GmailHistoryListRequest(startHistoryId: "90", pageToken: "resume", labelId: "INBOX")
    let pages: GmailHistoryPageSequence = client.historyPages(options)

    #expect(await transport.requests.isEmpty)
    #expect(await tokenProvider.retrievalCount == 0)
    var historyIDs: [String] = []
    for try await page in pages {
      historyIDs.append(page.historyId)
      await transport.setResponseBody(#"{"historyId":"200"}"#)
    }

    #expect(historyIDs == ["100", "200"])
    #expect(await tokenProvider.retrievalCount == 4)
    #expect(await tokenProvider.invalidatedTokens == ["rejected-first", "rejected-second"])
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
      "Bearer rejected-first", "Bearer valid-first", "Bearer rejected-second", "Bearer valid-second"
    ])
    for (request, pageToken) in zip(requests, ["resume", "resume", "second+/=%2F", "second+/=%2F"]) {
      let url = try #require(request.url)
      #expect(url.path == "/gmail/v1/users/me/history")
      let queryItems = try decodedQueryItems(in: url)
      #expect(queryItems.contains(URLQueryItem(name: "startHistoryId", value: "90")))
      #expect(queryItems.contains(URLQueryItem(name: "pageToken", value: pageToken)))
      #expect(queryItems.contains(URLQueryItem(name: "labelId", value: "INBOX")))
    }
  }

  private func decodedQueryItems(in url: URL) throws -> [URLQueryItem] {
    let urlComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let encodedQuery = try #require(urlComponents.percentEncodedQuery)
    var decodedComponents = URLComponents()
    // Match a query decoder that treats literal plus signs as spaces.
    decodedComponents.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%20")
    return try #require(decodedComponents.queryItems)
  }
}

extension GmailClientTests {
  enum CancellationStage: CaseIterable, Sendable {
    case beforeCredentials, credentials, response, invalidation
  }

  enum DependencyFailure: LocalizedError, Equatable, CaseIterable {
    case credentials, invalidation, transport

    var errorDescription: String? { "The test dependency failed." }
    var failureReason: String? { "The dependency was configured to fail." }
    var recoverySuggestion: String? { "Supply a working test dependency." }
  }
}

private extension GmailClientTests {
  actor TokenProvider: GmailTokenProvider {
    private let tokens: [String]
    private let failure: DependencyFailure?
    private let cancellationStage: CancellationStage?
    private let cancellationInvalidationCount: Int
    private(set) var retrievalCount = 0
    private(set) var invalidatedTokens: [String] = []

    init(
      tokens: [String] = ["first-token"],
      failure: DependencyFailure? = nil,
      cancellationStage: CancellationStage? = nil,
      cancellationInvalidationCount: Int = 1
    ) {
      self.tokens = tokens
      self.failure = failure
      self.cancellationStage = cancellationStage
      self.cancellationInvalidationCount = cancellationInvalidationCount
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
      if cancellationStage == .invalidation, invalidatedTokens.count == cancellationInvalidationCount {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
    }
  }

  actor Transport: GmailTransport {
    private let statusCodes: [Int]
    private var responseBody: String
    private let responseHeaders: [String: String]
    private let failure: DependencyFailure?
    private let cancellationStage: CancellationStage?
    private let errorsByRequestNumber: [Int: any Error]
    private(set) var requests: [URLRequest] = []

    init(
      statusCodes: [Int] = [200],
      responseBody: String = """
        {"emailAddress":"demo@example.com","messagesTotal":50,"threadsTotal":12,"historyId":"18446744073709551615"}
        """,
      responseHeaders: [String: String] = [:],
      failure: DependencyFailure? = nil,
      cancellationStage: CancellationStage? = nil,
      errorsByRequestNumber: [Int: any Error] = [:]
    ) {
      self.statusCodes = statusCodes
      self.responseBody = responseBody
      self.responseHeaders = responseHeaders
      self.failure = failure
      self.cancellationStage = cancellationStage
      self.errorsByRequestNumber = errorsByRequestNumber
    }

    func setResponseBody(_ responseBody: String) {
      self.responseBody = responseBody
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      requests.append(request)
      if let error = errorsByRequestNumber[requests.count] { throw error }
      if failure == .transport { throw DependencyFailure.transport }
      if cancellationStage == .response {
        withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      }
      let statusCode = statusCodes[min(requests.count - 1, statusCodes.count - 1)]
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: statusCode,
        httpVersion: nil, headerFields: responseHeaders
      ))
      return (Data(responseBody.utf8), response)
    }
  }

  actor RetryPolicy: GmailRetryPolicy {
    private let maximumRetries: Int
    private let cancelsTask: Bool
    private let failure: (any Error)?
    private(set) var retryCounts: [Int] = []
    private(set) var failures: [GmailRequestFailure] = []
    private(set) var transportErrors: [any Error] = []

    init(maximumRetries: Int = 1, cancelsTask: Bool = false, failure: (any Error)? = nil) {
      self.maximumRetries = maximumRetries
      self.cancelsTask = cancelsTask
      self.failure = failure
    }

    func waitBeforeRetry(after error: any Error, retryCount: Int) async throws -> Bool {
      retryCounts.append(retryCount)
      if let requestFailure = error as? GmailRequestFailure {
        failures.append(requestFailure)
      } else {
        transportErrors.append(error)
      }
      if cancelsTask { withUnsafeCurrentTask { currentTask in currentTask?.cancel() } }
      if let failure { throw failure }
      return retryCount < maximumRetries
    }
  }

  actor RetryingTransport: GmailTransport {
    private(set) var requestCounts: [URL: Int] = [:]

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
      let url = try #require(request.url)
      requestCounts[url, default: 0] += 1
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: requestCounts[url] == 1 ? 503 : 200, httpVersion: nil, headerFields: nil
      ))
      let responseBody = """
        {"emailAddress":"demo@example.com","messagesTotal":0,"threadsTotal":0,"historyId":"100","threads":[]}
        """
      return (Data(responseBody.utf8), response)
    }
  }
}
