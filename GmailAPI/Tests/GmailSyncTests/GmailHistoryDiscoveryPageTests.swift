import Foundation
import GmailAPI
import GmailSync
import Testing

struct GmailHistoryDiscoveryPageTests {
  @Test
  func coalescesEveryChangeListAcrossRecordsIntoConversationFetches() throws {
    let response = try decodeResponse(#"""
      {
        "historyId": "900",
        "history": [
          {
            "id": "201",
            "messages": [{"id":"m1","threadId":"shared"}, {"id":"m2","threadId":"general"}],
            "messagesAdded": [
              {"message":{"id":"m1","threadId":"shared"}},
              {"message":{"id":"m3","threadId":"added"}}
            ],
            "messagesDeleted": [{"message":{"id":"m4","threadId":"deleted"}}],
            "labelsAdded": [{"message":{"id":"m5","threadId":"labeled"},"labelIds":["INBOX"]}],
            "labelsRemoved": [{"message":{"id":"m6","threadId":"unlabeled"},"labelIds":["Work"]}]
          },
          {
            "id": "205",
            "messagesAdded": [{"message":{"id":"m7","threadId":"shared"}}],
            "labelsRemoved": [{"message":{"id":"m4","threadId":"deleted"},"labelIds":["TRASH"]}]
          }
        ]
      }
      """#)

    let page = try makePage(response: response)

    #expect(page.conversationIDs.map(\.threadID) == ["added", "deleted", "general", "labeled", "shared", "unlabeled"])
    #expect(page.conversationIDs.allSatisfy { $0.accountID == "account" })
  }

  @Test
  func retainsTheActualRequestAndDistinctResponseCursor() throws {
    let request = try GmailHistoryListRequest(startHistoryId: "000184467440737095516160", maxResults: 37, pageToken: "page+/=%2F")
    let response = try decodeResponse(#"{"historyId":"000184467440737095516999","nextPageToken":"next+/=%2F"}"#)
    let page = try GmailHistoryDiscoveryPage(accountID: " account ", request: request, response: response)

    #expect(page.accountID == " account ")
    #expect(page.request == request)
    #expect(page.historyId == response.historyId)
    #expect(page.nextPageToken == "next+/=%2F")
  }

  @Test(arguments: [
    #"{"historyId":"900"}"#,
    #"{"historyId":"900","history":null}"#,
    #"{"historyId":"900","history":[]}"#,
    #"{"historyId":"900","history":[{"id":"201"}]}"#
  ])
  func emptyHistoryStillCarriesAValidFinalCursor(json: String) throws {
    let page = try makePage(response: decodeResponse(json))

    #expect(page.conversationIDs.isEmpty)
    #expect(page.historyId == "900")
    #expect(page.nextPageToken == nil)
  }

  @Test
  func anEmptyIntermediatePageRetainsItsContinuation() throws {
    let page = try makePage(response: decodeResponse(#"{"historyId":"900","nextPageToken":"next"}"#))

    #expect(page.conversationIDs.isEmpty)
    #expect(page.nextPageToken == "next")
  }

  @Test(arguments: [("", nil), (" ", " "), ("+/=%2F", "+/=%2F")] as [(String, String?)])
  func onlyAnEmptyResponseTokenIsNormalized(token: String, expected: String?) throws {
    let data = try JSONSerialization.data(withJSONObject: ["historyId": "900", "nextPageToken": token])
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: data)

    #expect(try makePage(response: response).nextPageToken == expected)
  }

  @Test
  func identicalThreadIDsInDifferentAccountsRemainDifferentWork() throws {
    let response = try decodeResponse(#"{"historyId":"900","history":[{"id":"201","messages":[{"id":"m","threadId":"shared"}]}]}"#)
    let request = try GmailHistoryListRequest(startHistoryId: "100")
    let first = try GmailHistoryDiscoveryPage(accountID: "first", request: request, response: response)
    let second = try GmailHistoryDiscoveryPage(accountID: "second", request: request, response: response)

    #expect(Set(first.conversationIDs + second.conversationIDs).count == 2)
  }

  @Test
  func preservesOpaqueThreadIDsAndProducesDeterministicWorkOrder() throws {
    let threadIDs = ["000abc+/=%2F", "ABC", "abc", " padded "]
    let messages = threadIDs.map { threadID in ["id": "message-" + threadID, "threadId": threadID] }
    let first = try pageWithMessages(messages)
    let reordered = try pageWithMessages(Array(messages.reversed()) + messages)

    #expect(first.conversationIDs.map(\.threadID) == threadIDs.sorted())
    #expect(first == reordered)
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankAccountsEvenForEmptyPages(accountID: String) throws {
    let request = try GmailHistoryListRequest(startHistoryId: "100")
    let response = try decodeResponse(#"{"historyId":"900"}"#)

    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailHistoryDiscoveryPage(accountID: accountID, request: request, response: response)
    }
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankResponseCursors(historyId: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["historyId": historyId])
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: data)

    #expect(throws: GmailHistoryDiscoveryPage.ValidationError.missingHistoryID) {
      try makePage(response: response)
    }
  }

  @Test(arguments: ["messages", "messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved"])
  func neverDropsMalformedConversationReferences(field: String) throws {
    let malformedMessage = ["id": "bad", "threadId": " \n"]
    let entry: [String: Any] = field == "messages" ? malformedMessage : ["message": malformedMessage, "labelIds": ["Work"]]
    let records: [[String: Any]] = [
      ["id": "201", "messages": [["id": "good", "threadId": "valid"]]],
      ["id": "205", field: [entry]]
    ]
    let data = try JSONSerialization.data(withJSONObject: ["historyId": "900", "history": records])
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: data)

    #expect(throws: GmailConversationID.ValidationError.emptyThreadID) {
      try makePage(response: response)
    }
  }

  @Test(arguments: ["INBOX", ""])
  func rejectsLabelFilteredHistory(labelID: String) throws {
    let request = try GmailHistoryListRequest(startHistoryId: "100", labelId: labelID)
    let response = try decodeResponse(#"{"historyId":"900"}"#)

    #expect(throws: GmailHistoryDiscoveryPage.ValidationError.filteredRequest) {
      try GmailHistoryDiscoveryPage(accountID: "account", request: request, response: response)
    }
  }

  @Test(arguments: [[GmailHistoryListRequest.HistoryType.messageAdded], GmailHistoryListRequest.HistoryType.allCases])
  func rejectsExplicitChangeTypeFilters(historyTypes: [GmailHistoryListRequest.HistoryType]) throws {
    let request = try GmailHistoryListRequest(startHistoryId: "100", historyTypes: historyTypes)
    let response = try decodeResponse(#"{"historyId":"900"}"#)

    #expect(throws: GmailHistoryDiscoveryPage.ValidationError.filteredRequest) {
      try GmailHistoryDiscoveryPage(accountID: "account", request: request, response: response)
    }
  }

  @Test(arguments: [GmailHistoryDiscoveryPage.ValidationError.filteredRequest, .missingHistoryID])
  func providesLocalizedRecoveryGuidance(error: GmailHistoryDiscoveryPage.ValidationError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}

private extension GmailHistoryDiscoveryPageTests {
  func decodeResponse(_ json: String) throws -> GmailHistoryListResponse {
    try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))
  }

  func makePage(response: GmailHistoryListResponse) throws -> GmailHistoryDiscoveryPage {
    try GmailHistoryDiscoveryPage(accountID: "account", request: GmailHistoryListRequest(startHistoryId: "100"), response: response)
  }

  func pageWithMessages(_ messages: [[String: String]]) throws -> GmailHistoryDiscoveryPage {
    let data = try JSONSerialization.data(withJSONObject: ["historyId": "900", "history": [["id": "201", "messages": messages]]])
    return try makePage(response: JSONDecoder().decode(GmailHistoryListResponse.self, from: data))
  }
}
