import Foundation
import GmailAPI
import GmailSync
import Testing

struct GmailThreadDiscoveryPageTests {
  private let importGeneration = UUID()

  @Test
  func deduplicatesConversationsAndPreservesOpaqueIDs() throws {
    let response = try decodeResponse(#"""
      {"threads":[{"id":"b"},{"id":"000a+/=%2F"},{"id":"b"},{"id":"A"},{"id":" padded "}]}
      """#)
    let page = try makePage(response: response)

    #expect(page.conversationIDs.map(\.threadID) == [" padded ", "000a+/=%2F", "A", "b"])
    #expect(page.conversationIDs.allSatisfy { conversationID in conversationID.accountID == "account" })
  }

  @Test
  func preservesAccountGenerationAndExactRequest() throws {
    let request = try GmailThreadListRequest(maxResults: 37, pageToken: "page+/=%2F", includeSpamTrash: true)
    let page = try GmailThreadDiscoveryPage(
      accountID: " account ", importGeneration: importGeneration,
      request: request, response: decodeResponse(#"{"nextPageToken":"next+/=%2F"}"#)
    )

    #expect(page.accountID == " account ")
    #expect(page.importGeneration == importGeneration)
    #expect(page.request == request)
    #expect(page.nextPageToken == "next+/=%2F")
  }

  @Test
  func separatesAccountsAndImportGenerations() throws {
    let response = try decodeResponse(#"{"threads":[{"id":"shared"}]}"#)
    let original = try makePage(response: response)
    let otherAccount = try GmailThreadDiscoveryPage(
      accountID: "other", importGeneration: importGeneration, request: original.request, response: response
    )
    let otherImport = try GmailThreadDiscoveryPage(
      accountID: "account", importGeneration: UUID(), request: original.request, response: response
    )

    #expect(original.conversationIDs != otherAccount.conversationIDs)
    #expect(original != otherImport)
    #expect(original.conversationIDs == otherImport.conversationIDs)
  }

  @Test(arguments: ["{}", #"{"threads":null}"#, #"{"threads":[]}"#])
  func omittedOrEmptyThreadsFormAnEmptyFinalPage(json: String) throws {
    let page = try makePage(response: decodeResponse(json))

    #expect(page.conversationIDs.isEmpty)
    #expect(page.nextPageToken == nil)
  }

  @Test
  func anEmptyIntermediatePageStillContinuesDespiteAZeroEstimate() throws {
    let page = try makePage(response: decodeResponse(#"{"threads":[],"nextPageToken":"next","resultSizeEstimate":0}"#))

    #expect(page.conversationIDs.isEmpty)
    #expect(page.nextPageToken == "next")
  }

  @Test
  func aNonzeroEstimateDoesNotKeepAFinalPageOpen() throws {
    let page = try makePage(response: decodeResponse(#"{"threads":[{"id":"last"}],"resultSizeEstimate":1000}"#))

    #expect(page.conversationIDs.map(\.threadID) == ["last"])
    #expect(page.nextPageToken == nil)
  }

  @Test(arguments: [("", nil), (" ", " "), ("+/=%2F", "+/=%2F")] as [(String, String?)])
  func onlyAnEmptyResponseTokenIsNormalized(token: String, expected: String?) throws {
    let data = try JSONSerialization.data(withJSONObject: ["nextPageToken": token])
    let response = try JSONDecoder().decode(GmailThreadListResponse.self, from: data)

    #expect(try makePage(response: response).nextPageToken == expected)
  }

  @Test(arguments: [false, true])
  func acceptsEitherExplicitSpamTrashSetting(includeSpamTrash: Bool) throws {
    let request = try GmailThreadListRequest(includeSpamTrash: includeSpamTrash)
    let page = try GmailThreadDiscoveryPage(
      accountID: "account", importGeneration: importGeneration, request: request, response: decodeResponse("{}")
    )

    #expect(page.request.includeSpamTrash == includeSpamTrash)
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankAccountsEvenForEmptyPages(accountID: String) throws {
    let request = try GmailThreadListRequest()
    let response = try decodeResponse("{}")

    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailThreadDiscoveryPage(accountID: accountID, importGeneration: importGeneration, request: request, response: response)
    }
  }

  @Test(arguments: ["", " ", "\t\n"])
  func malformedThreadIDsFailTheWholePage(threadID: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["threads": [["id": "valid"], ["id": threadID]]])
    let response = try JSONDecoder().decode(GmailThreadListResponse.self, from: data)

    #expect(throws: GmailConversationID.ValidationError.emptyThreadID) {
      try makePage(response: response)
    }
  }

  @Test(arguments: ["after:2026/01/01", " "])
  func rejectsSearchFilteredDiscovery(query: String) throws {
    let request = try GmailThreadListRequest(q: query)
    let response = try decodeResponse("{}")

    #expect(throws: GmailThreadDiscoveryPage.ValidationError.filteredRequest) {
      try GmailThreadDiscoveryPage(accountID: "account", importGeneration: importGeneration, request: request, response: response)
    }
  }

  @Test(arguments: [["INBOX"], [""]])
  func rejectsLabelFilteredDiscovery(labelIDs: [String]) throws {
    let request = try GmailThreadListRequest(labelIds: labelIDs)
    let response = try decodeResponse("{}")

    #expect(throws: GmailThreadDiscoveryPage.ValidationError.filteredRequest) {
      try GmailThreadDiscoveryPage(accountID: "account", importGeneration: importGeneration, request: request, response: response)
    }
  }

  @Test
  func providesLocalizedRecoveryGuidance() throws {
    let error = GmailThreadDiscoveryPage.ValidationError.filteredRequest

    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}

private extension GmailThreadDiscoveryPageTests {
  func decodeResponse(_ json: String) throws -> GmailThreadListResponse {
    try JSONDecoder().decode(GmailThreadListResponse.self, from: Data(json.utf8))
  }

  func makePage(response: GmailThreadListResponse) throws -> GmailThreadDiscoveryPage {
    try GmailThreadDiscoveryPage(
      accountID: "account", importGeneration: importGeneration, request: GmailThreadListRequest(), response: response
    )
  }
}
