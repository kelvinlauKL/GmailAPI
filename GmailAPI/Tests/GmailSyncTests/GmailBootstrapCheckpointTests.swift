import Foundation
import GmailAPI
import GmailSync
import Testing

struct GmailBootstrapCheckpointTests {
  private let importGeneration = UUID()

  @Test(arguments: [false, true])
  func buildsBroadRequestsUsingTheFixedPolicy(includeSpamTrash: Bool) throws {
    let policy = try GmailSyncPolicy(
      version: 3, oldestMessageDate: Date(timeIntervalSince1970: 1_700_000_000),
      requiredLabelIds: ["Work"], includeSpamTrash: includeSpamTrash, includeDrafts: true
    )
    let checkpoint = try GmailBootstrapCheckpoint(
      accountID: "account", importGeneration: importGeneration, policy: policy, baselineHistoryId: "100", maxResults: 37
    )
    let request = try #require(try checkpoint.makeRequest())

    #expect(checkpoint.policy == policy)
    #expect(checkpoint.position == .listing(pageToken: nil))
    #expect(request.q.isEmpty)
    #expect(request.labelIds.isEmpty)
    #expect(request.maxResults == 37)
    #expect(request.pageToken == nil)
    #expect(request.includeSpamTrash == includeSpamTrash)
  }

  @Test
  func resumesListingAfterSerializationAndReplaysTheOriginalBaseline() throws {
    let original = try makeCheckpoint()
    let firstPage = try makePage(checkpoint: original, json: #"{"threads":[{"id":"thread","historyId":"9999"}],"nextPageToken":"second"}"#)
    let intermediate = try roundTrip(original.advancing(after: firstPage))

    #expect(original.position == .listing(pageToken: nil))
    #expect(intermediate.position == .listing(pageToken: "second"))
    #expect(try intermediate.makeRequest()?.pageToken == "second")
    #expect(intermediate.policy == original.policy)
    #expect(intermediate.baselineHistoryId == original.baselineHistoryId)
    #expect(intermediate.importGeneration == original.importGeneration)
    #expect(intermediate.maxResults == original.maxResults)

    let finalPage = try makePage(checkpoint: intermediate, json: #"{"threads":[{"id":"last","historyId":"99999"}]}"#)
    let completed = try roundTrip(intermediate.advancing(after: finalPage))
    let history = try completed.makeHistoryCheckpoint(maxResults: 23)

    #expect(completed.position == .awaitingHistoryReplay)
    #expect(try completed.makeRequest() == nil)
    #expect(completed.policy == original.policy)
    #expect(completed.importGeneration == original.importGeneration)
    #expect(completed.maxResults == original.maxResults)
    #expect(history.accountID == original.accountID)
    #expect(history.historyId == original.baselineHistoryId)
    #expect(history.pageToken == nil)
    #expect(history.maxResults == 23)
  }

  @Test(arguments: [nil, "next"] as [String?])
  func cannotStartHistoryReplayWhileListing(pageToken: String?) throws {
    let checkpoint = try makeCheckpoint(position: .listing(pageToken: pageToken))

    #expect(throws: GmailBootstrapCheckpoint.TransitionError.listingNotComplete) {
      try checkpoint.makeHistoryCheckpoint()
    }
  }

  @Test(arguments: [#"{"resultSizeEstimate":1000}"#, #"{"nextPageToken":"","resultSizeEstimate":1000}"#])
  func anEmptyFinalPageFinishesEnumerationRegardlessOfEstimate(json: String) throws {
    let checkpoint = try makeCheckpoint()
    let successor = try checkpoint.advancing(after: makePage(checkpoint: checkpoint, json: json))

    #expect(successor.position == .awaitingHistoryReplay)
    #expect(try successor.makeRequest() == nil)
  }

  @Test
  func anEmptyIntermediatePageStillNeedsListing() throws {
    let checkpoint = try makeCheckpoint()
    let page = try makePage(checkpoint: checkpoint, json: #"{"resultSizeEstimate":0,"nextPageToken":"next"}"#)

    #expect(try checkpoint.advancing(after: page).position == .listing(pageToken: "next"))
  }

  @Test
  func refusesFurtherListingPagesAfterEnumerationFinishes() throws {
    let original = try makeCheckpoint()
    let page = try makePage(checkpoint: original, json: "{}")
    let completed = try original.advancing(after: page)

    #expect(throws: GmailBootstrapCheckpoint.TransitionError.listingAlreadyComplete) {
      try completed.advancing(after: page)
    }
  }

  @Test
  func rejectsOtherAccountsAndGenerationsEvenWithIdenticalRequests() throws {
    let checkpoint = try makeCheckpoint()
    let request = try #require(try checkpoint.makeRequest())
    let response = try JSONDecoder().decode(GmailThreadListResponse.self, from: Data("{}".utf8))
    let otherAccount = try GmailThreadDiscoveryPage(
      accountID: "other", importGeneration: importGeneration, request: request, response: response
    )
    let otherGeneration = try GmailThreadDiscoveryPage(
      accountID: checkpoint.accountID, importGeneration: UUID(), request: request, response: response
    )

    #expect(throws: GmailBootstrapCheckpoint.TransitionError.accountMismatch) {
      try checkpoint.advancing(after: otherAccount)
    }
    #expect(throws: GmailBootstrapCheckpoint.TransitionError.importGenerationMismatch) {
      try checkpoint.advancing(after: otherGeneration)
    }
  }

  @Test(arguments: [(38, "current", true), (37, "other", true), (37, "current", false)])
  func rejectsChangedListingSettings(maxResults: Int, pageToken: String, includeSpamTrash: Bool) throws {
    let checkpoint = try makeCheckpoint(position: .listing(pageToken: "current"))
    let request = try GmailThreadListRequest(maxResults: maxResults, pageToken: pageToken, includeSpamTrash: includeSpamTrash)
    let response = try JSONDecoder().decode(GmailThreadListResponse.self, from: Data("{}".utf8))
    let page = try GmailThreadDiscoveryPage(
      accountID: checkpoint.accountID, importGeneration: importGeneration, request: request, response: response
    )

    #expect(throws: GmailBootstrapCheckpoint.TransitionError.requestMismatch) {
      try checkpoint.advancing(after: page)
    }
  }

  @Test
  func rejectsReplayAgainstAnAdvancedCheckpointAndImmediateTokenRepetition() throws {
    let original = try makeCheckpoint()
    let firstPage = try makePage(checkpoint: original, json: #"{"nextPageToken":"next"}"#)
    let advanced = try original.advancing(after: firstPage)

    #expect(throws: GmailBootstrapCheckpoint.TransitionError.requestMismatch) {
      try advanced.advancing(after: firstPage)
    }
    let repeated = try makePage(checkpoint: advanced, json: #"{"nextPageToken":"next"}"#)
    #expect(throws: GmailBootstrapCheckpoint.TransitionError.repeatedPageToken) {
      try advanced.advancing(after: repeated)
    }
  }

  @Test(arguments: [nil, "", " ", "opaque+/=%2F"] as [String?])
  func persistencePreservesOpaqueTokensAndFullPolicy(pageToken: String?) throws {
    let checkpoint = try makeCheckpoint(position: .listing(pageToken: pageToken))
    let restored = try roundTrip(checkpoint)

    #expect(restored == checkpoint)
    #expect(try restored.makeRequest()?.pageToken == pageToken)
    #expect(restored.baselineHistoryId == "000184467440737095516160")
  }

  @Test(arguments: ["", " ", "\t\n"])
  func rejectsBlankAccountAndBaselineValues(value: String) throws {
    let policy = try GmailSyncPolicy(version: 1)

    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailBootstrapCheckpoint(accountID: value, importGeneration: importGeneration, policy: policy, baselineHistoryId: "100")
    }
    #expect(throws: GmailHistoryListRequest.ValidationError.missingStartHistoryID) {
      try GmailBootstrapCheckpoint(accountID: "account", importGeneration: importGeneration, policy: policy, baselineHistoryId: value)
    }
  }

  @Test(arguments: [0, -1, 501])
  func validatesBothListingAndHistoryPageSizes(maxResults: Int) throws {
    let checkpoint = try makeCheckpoint(position: .awaitingHistoryReplay)

    #expect(throws: GmailThreadListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try GmailBootstrapCheckpoint(
        accountID: checkpoint.accountID, importGeneration: importGeneration, policy: checkpoint.policy,
        baselineHistoryId: checkpoint.baselineHistoryId, maxResults: maxResults
      )
    }
    #expect(throws: GmailHistoryListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try checkpoint.makeHistoryCheckpoint(maxResults: maxResults)
    }
  }

  @Test(arguments: ["accountID", "baselineHistoryId", "importGeneration", "maxResults", "policy", "position"])
  func decodingRejectsMissingAndInvalidStoredState(field: String) throws {
    let checkpoint = try makeCheckpoint()
    let data = try JSONEncoder().encode(checkpoint)
    var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    fields.removeValue(forKey: field)
    let missing = try JSONSerialization.data(withJSONObject: fields)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailBootstrapCheckpoint.self, from: missing)
    }
    fields[field] = ""
    let invalid = try JSONSerialization.data(withJSONObject: fields)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(GmailBootstrapCheckpoint.self, from: invalid)
    }
  }

  @Test
  func decodingRevalidatesStoredPageSizeAndPolicyVersion() throws {
    let checkpoint = try makeCheckpoint()
    let data = try JSONEncoder().encode(checkpoint)
    var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    fields["maxResults"] = 0
    let invalidPageSize = try JSONSerialization.data(withJSONObject: fields)

    #expect(throws: GmailThreadListRequest.ValidationError.invalidMaxResults(0)) {
      try JSONDecoder().decode(GmailBootstrapCheckpoint.self, from: invalidPageSize)
    }
    fields["maxResults"] = checkpoint.maxResults
    var policyFields = try #require(fields["policy"] as? [String: Any])
    policyFields["version"] = 0
    fields["policy"] = policyFields
    let invalidPolicy = try JSONSerialization.data(withJSONObject: fields)

    #expect(throws: GmailSyncPolicy.ValidationError.invalidVersion(0)) {
      try JSONDecoder().decode(GmailBootstrapCheckpoint.self, from: invalidPolicy)
    }
  }

  @Test
  func decodingRejectsContradictoryPositions() throws {
    let checkpoint = try makeCheckpoint()
    let data = try JSONEncoder().encode(checkpoint)
    var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    fields["position"] = ["listing": ["pageToken": "next"], "awaitingHistoryReplay": [:]]
    let invalid = try JSONSerialization.data(withJSONObject: fields)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailBootstrapCheckpoint.self, from: invalid)
    }
  }

  @Test(arguments: [
    GmailBootstrapCheckpoint.TransitionError.listingAlreadyComplete, .listingNotComplete, .accountMismatch,
    .importGenerationMismatch, .requestMismatch, .repeatedPageToken
  ])
  func providesLocalizedRecoveryGuidance(error: GmailBootstrapCheckpoint.TransitionError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}

private extension GmailBootstrapCheckpointTests {
  func makeCheckpoint(position: GmailBootstrapCheckpoint.Position = .listing(pageToken: nil)) throws -> GmailBootstrapCheckpoint {
    let policy = try GmailSyncPolicy(
      version: 3, oldestMessageDate: Date(timeIntervalSince1970: 1_700_000_000),
      requiredLabelIds: ["Work", "INBOX"], includeSpamTrash: true, includeDrafts: true
    )
    return try GmailBootstrapCheckpoint(
      accountID: " account ", importGeneration: importGeneration, policy: policy,
      baselineHistoryId: "000184467440737095516160", maxResults: 37, position: position
    )
  }

  func makePage(checkpoint: GmailBootstrapCheckpoint, json: String) throws -> GmailThreadDiscoveryPage {
    let request = try #require(try checkpoint.makeRequest())
    let response = try JSONDecoder().decode(GmailThreadListResponse.self, from: Data(json.utf8))
    return try GmailThreadDiscoveryPage(
      accountID: checkpoint.accountID, importGeneration: checkpoint.importGeneration, request: request, response: response
    )
  }

  func roundTrip(_ checkpoint: GmailBootstrapCheckpoint) throws -> GmailBootstrapCheckpoint {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(GmailBootstrapCheckpoint.self, from: encoder.encode(checkpoint))
  }
}
