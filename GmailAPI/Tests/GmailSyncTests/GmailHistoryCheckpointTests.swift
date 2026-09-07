import Foundation
import GmailAPI
import GmailSync
import Testing

struct GmailHistoryCheckpointTests {
  @Test
  func startsWithAnUnfilteredRequestAtTheCommittedCursor() throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100")
    let request = try checkpoint.makeRequest()

    #expect(checkpoint.accountID == "account")
    #expect(request.startHistoryId == "100")
    #expect(request.maxResults == GmailHistoryListRequest.Constant.defaultPageSize)
    #expect(request.pageToken == nil)
    #expect(request.labelId == nil)
    #expect(request.historyTypes.isEmpty)
  }

  @Test
  func resumesAcrossRestartsAndCommitsOnlyTheFinalPageCursor() throws {
    let original = try GmailHistoryCheckpoint(accountID: "account", historyId: "100", maxResults: 37)
    let firstPage = try makePage(checkpoint: original, historyId: "900", nextPageToken: "second")
    let afterFirst = try original.advancing(after: firstPage)
    let restoredFirst = try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: JSONEncoder().encode(afterFirst))

    #expect(original.historyId == "100")
    #expect(original.pageToken == nil)
    #expect(restoredFirst.historyId == "100")
    #expect(try restoredFirst.makeRequest() == GmailHistoryListRequest(startHistoryId: "100", maxResults: 37, pageToken: "second"))

    let secondPage = try makePage(checkpoint: restoredFirst, historyId: "950", nextPageToken: "third")
    let afterSecond = try restoredFirst.advancing(after: secondPage)
    let restoredSecond = try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: JSONEncoder().encode(afterSecond))

    #expect(restoredSecond.historyId == "100")
    #expect(restoredSecond.pageToken == "third")
    #expect(restoredSecond.maxResults == 37)

    let finalPage = try makePage(checkpoint: restoredSecond, historyId: "1000")
    let completed = try restoredSecond.advancing(after: finalPage)

    #expect(completed.historyId == "1000")
    #expect(completed.pageToken == nil)
    #expect(try completed.makeRequest() == GmailHistoryListRequest(startHistoryId: "1000", maxResults: 37))
  }

  @Test(arguments: [nil, ""] as [String?])
  func anEmptyFinalPageStillAdvancesTheCursor(nextPageToken: String?) throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100", pageToken: "last")
    let page = try makePage(checkpoint: checkpoint, historyId: "900", nextPageToken: nextPageToken)
    let successor = try checkpoint.advancing(after: page)

    #expect(page.conversationIDs.isEmpty)
    #expect(successor.historyId == "900")
    #expect(successor.pageToken == nil)
  }

  @Test
  func aMailboxWithNoNewHistoryCanKeepTheSameCursor() throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100")
    let page = try makePage(checkpoint: checkpoint, historyId: "100")

    #expect(try checkpoint.advancing(after: page) == checkpoint)
  }

  @Test
  func rejectsPagesFromAnotherAccountEvenWhenRequestsMatch() throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100")
    let otherAccount = try GmailHistoryCheckpoint(accountID: "other", historyId: "100")
    let page = try makePage(checkpoint: otherAccount, historyId: "900")

    #expect(throws: GmailHistoryCheckpoint.AdvancementError.accountMismatch) {
      try checkpoint.advancing(after: page)
    }
  }

  @Test(arguments: [("99", 37, "current"), ("100", 38, "current"), ("100", 37, "other")])
  func rejectsMismatchedRequestSettings(historyId: String, maxResults: Int, pageToken: String) throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100", maxResults: 37, pageToken: "current")
    let mismatched = try GmailHistoryCheckpoint(accountID: "account", historyId: historyId, maxResults: maxResults, pageToken: pageToken)
    let page = try makePage(checkpoint: mismatched, historyId: "900")

    #expect(throws: GmailHistoryCheckpoint.AdvancementError.requestMismatch) {
      try checkpoint.advancing(after: page)
    }
  }

  @Test
  func rejectsReplayingPagesAgainstAnAdvancedCheckpoint() throws {
    let original = try GmailHistoryCheckpoint(accountID: "account", historyId: "100")
    let firstPage = try makePage(checkpoint: original, historyId: "900", nextPageToken: "next")
    let intermediate = try original.advancing(after: firstPage)

    #expect(throws: GmailHistoryCheckpoint.AdvancementError.requestMismatch) {
      try intermediate.advancing(after: firstPage)
    }
    let finalPage = try makePage(checkpoint: intermediate, historyId: "1000")
    #expect(throws: GmailHistoryCheckpoint.AdvancementError.requestMismatch) {
      try original.advancing(after: finalPage)
    }
    let completed = try intermediate.advancing(after: finalPage)
    #expect(throws: GmailHistoryCheckpoint.AdvancementError.requestMismatch) {
      try completed.advancing(after: finalPage)
    }
  }

  @Test
  func rejectsAResponseThatRepeatsTheRequestedPageToken() throws {
    let checkpoint = try GmailHistoryCheckpoint(accountID: "account", historyId: "100", pageToken: "same")
    let page = try makePage(checkpoint: checkpoint, historyId: "900", nextPageToken: "same")

    #expect(throws: GmailHistoryCheckpoint.AdvancementError.repeatedPageToken) {
      try checkpoint.advancing(after: page)
    }
    #expect(checkpoint.historyId == "100")
    #expect(checkpoint.pageToken == "same")
  }

  @Test(arguments: [nil, "", " ", "page+/=%2F"] as [String?])
  func persistencePreservesOpaqueIdentifiersAndRequestTokens(pageToken: String?) throws {
    let checkpoint = try GmailHistoryCheckpoint(
      accountID: " account ", historyId: "000184467440737095516160", maxResults: 37, pageToken: pageToken
    )
    let data = try JSONEncoder().encode(checkpoint)
    let restored = try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: data)
    let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(restored == checkpoint)
    #expect(fields["accountID"] as? String == checkpoint.accountID)
    #expect(fields["historyId"] as? String == checkpoint.historyId)
    #expect(fields["maxResults"] as? Int == 37)
    #expect(try restored.makeRequest().pageToken == pageToken)
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankAccountsDuringInitializationAndDecoding(accountID: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["accountID": accountID, "historyId": "100", "maxResults": 37])

    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailHistoryCheckpoint(accountID: accountID, historyId: "100")
    }
    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: data)
    }
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankCursorsDuringInitializationAndDecoding(historyId: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["accountID": "account", "historyId": historyId, "maxResults": 37])

    #expect(throws: GmailHistoryListRequest.ValidationError.missingStartHistoryID) {
      try GmailHistoryCheckpoint(accountID: "account", historyId: historyId)
    }
    #expect(throws: GmailHistoryListRequest.ValidationError.missingStartHistoryID) {
      try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: data)
    }
  }

  @Test(arguments: [0, -1, 501, Int.max])
  func rejectsInvalidPageSizesDuringInitializationAndDecoding(maxResults: Int) throws {
    let data = try JSONSerialization.data(withJSONObject: ["accountID": "account", "historyId": "100", "maxResults": maxResults])

    #expect(throws: GmailHistoryListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try GmailHistoryCheckpoint(accountID: "account", historyId: "100", maxResults: maxResults)
    }
    #expect(throws: GmailHistoryListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: data)
    }
  }

  @Test(arguments: [
    "{}", #"{"accountID":"account","historyId":"100"}"#,
    #"{"accountID":"account","historyId":100,"maxResults":37}"#,
    #"{"accountID":"account","historyId":"100","maxResults":37,"pageToken":1}"#
  ])
  func rejectsIncompleteOrMistypedStoredCheckpoints(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryCheckpoint.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    GmailHistoryCheckpoint.AdvancementError.accountMismatch, .requestMismatch, .repeatedPageToken
  ])
  func providesLocalizedRecoveryGuidance(error: GmailHistoryCheckpoint.AdvancementError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}

private extension GmailHistoryCheckpointTests {
  func makePage(checkpoint: GmailHistoryCheckpoint, historyId: String, nextPageToken: String? = nil) throws -> GmailHistoryDiscoveryPage {
    var fields: [String: Any] = ["historyId": historyId]
    if let nextPageToken { fields["nextPageToken"] = nextPageToken }
    let data = try JSONSerialization.data(withJSONObject: fields)
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: data)
    return try GmailHistoryDiscoveryPage(accountID: checkpoint.accountID, request: checkpoint.makeRequest(), response: response)
  }
}
