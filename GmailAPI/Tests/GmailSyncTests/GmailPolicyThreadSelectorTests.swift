import Foundation
import GmailAPI
import GmailSync
import Testing

struct GmailPolicyThreadSelectorTests {
  private let selector: any GmailThreadSelector = GmailPolicyThreadSelector()

  @Test
  func defaultsExcludeDraftsSpamAndTrashFromContext() throws {
    let thread = try makeThread([
      message("ordinary"), message("draft", labels: ["DRAFT"]),
      message("spam", labels: ["SPAM"]), message("trash", labels: ["TRASH"]),
      message("unlabeled", labels: nil)
    ])

    let selected = try selector.messages(in: thread, matching: GmailSyncPolicy(version: 1))

    #expect(selected.map(\.id) == ["ordinary", "unlabeled"])
    #expect(selected == [thread.messages[0], thread.messages[4]])
  }

  @Test(arguments: [false, true], [false, true])
  func inclusionFlagsActIndependently(includeDrafts: Bool, includeSpamTrash: Bool) throws {
    let thread = try makeThread([
      message("ordinary"), message("draft", labels: ["DRAFT"]),
      message("spam", labels: ["SPAM"]), message("trash", labels: ["TRASH"]),
      message("both", labels: ["DRAFT", "TRASH"])
    ])
    let policy = try GmailSyncPolicy(
      version: 1, includeSpamTrash: includeSpamTrash, includeDrafts: includeDrafts
    )

    let selectedIDs = try selector.messages(in: thread, matching: policy).map(\.id)

    #expect(selectedIDs.contains("ordinary"))
    #expect(selectedIDs.contains("draft") == includeDrafts)
    #expect(selectedIDs.contains("spam") == includeSpamTrash)
    #expect(selectedIDs.contains("trash") == includeSpamTrash)
    #expect(selectedIDs.contains("both") == (includeDrafts && includeSpamTrash))
  }

  @Test
  func retainsOlderAndUnlabeledContextInSourceOrder() throws {
    let thread = try makeThread([
      message("reply", labels: ["Work", "INBOX"], internalDate: "2000"),
      message("earlier", labels: [], internalDate: "500"),
      message("other", labels: ["Other"], internalDate: "3000")
    ])
    let policy = try GmailSyncPolicy(
      version: 1, oldestMessageDate: Date(timeIntervalSince1970: 2),
      requiredLabelIds: ["INBOX", "Work"]
    )

    #expect(try selector.messages(in: thread, matching: policy) == thread.messages)
  }

  @Test
  func dateAndEveryRequiredLabelMustMatchTheSameMessage() throws {
    let thread = try makeThread([
      message("old", labels: ["INBOX", "Work"], internalDate: "1999"),
      message("new-inbox", labels: ["INBOX"], internalDate: "2000"),
      message("new-work", labels: ["Work"], internalDate: "2000")
    ])
    let policy = try GmailSyncPolicy(
      version: 1, oldestMessageDate: Date(timeIntervalSince1970: 2),
      requiredLabelIds: ["INBOX", "Work"]
    )

    #expect(try selector.messages(in: thread, matching: policy).isEmpty)
  }

  @Test(arguments: ["DRAFT", "SPAM", "TRASH"])
  func excludedMessagesCannotQualifyTheThread(labelID: String) throws {
    let thread = try makeThread([
      message("excluded", labels: [labelID, "Work"]), message("context", labels: [])
    ])
    let policy = try GmailSyncPolicy(version: 1, requiredLabelIds: ["Work"])

    #expect(try selector.messages(in: thread, matching: policy).isEmpty)
  }

  @Test
  func evaluatesLabelsExactlyAndTreatsOmittedLabelsAsEmpty() throws {
    let thread = try makeThread([
      message("lowercase", labels: ["work"]), message("spaces", labels: [" Work "]),
      message("missing", labels: nil)
    ])

    #expect(try selector.messages(in: thread, matching: GmailSyncPolicy(version: 1, requiredLabelIds: ["Work"])).isEmpty)
    #expect(try selector.messages(in: thread, matching: GmailSyncPolicy(version: 1, requiredLabelIds: ["work"])) == thread.messages)
  }

  @Test(arguments: [("1999", false), ("2000", true), ("2001", true)])
  func dateBoundIsInclusiveAndUsesMilliseconds(internalDate: String, qualifies: Bool) throws {
    let thread = try makeThread([message("message", internalDate: internalDate)])
    let policy = try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: 2))

    #expect(try !selector.messages(in: thread, matching: policy).isEmpty == qualifies)
  }

  @Test
  func supportsDatesBeforeTheUnixEpochWithoutRoundingToWholeSeconds() throws {
    let thread = try makeThread([message("message", internalDate: "-500")])
    let matching = try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: -0.5))
    let later = try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: -0.4995))

    #expect(try selector.messages(in: thread, matching: matching) == thread.messages)
    #expect(try selector.messages(in: thread, matching: later).isEmpty)
  }

  @Test(arguments: [nil, "", "1.5", "1e3", "NaN", " 1000", "９９９９", "9223372036854775808"] as [String?])
  func failsWhenAnUnknownDatePreventsASelectionDecision(internalDate: String?) throws {
    let thread = try makeThread([message("unknown", internalDate: internalDate)])
    let policy = try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: 0))

    #expect(throws: GmailPolicyThreadSelector.SelectionError.invalidInternalDate) {
      try selector.messages(in: thread, matching: policy)
    }
  }

  @Test(arguments: [false, true])
  func aKnownMatchMakesAnUnknownContextDateIrrelevantRegardlessOfOrder(reverse: Bool) throws {
    let messages = [message("unknown", internalDate: nil), message("match", internalDate: "2000")]
    let thread = try makeThread(reverse ? Array(messages.reversed()) : messages)
    let policy = try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: 2))

    #expect(try selector.messages(in: thread, matching: policy) == thread.messages)
  }

  @Test
  func doesNotNeedDatesForMessagesThatCannotQualifyOrForAnUnboundedPolicy() throws {
    let thread = try makeThread([
      message("draft", labels: ["DRAFT", "Work"], internalDate: nil),
      message("wrong-label", labels: [], internalDate: nil)
    ])
    let bounded = try GmailSyncPolicy(
      version: 1, oldestMessageDate: Date(timeIntervalSince1970: 2), requiredLabelIds: ["Work"]
    )

    #expect(try selector.messages(in: thread, matching: bounded).isEmpty)
    #expect(try selector.messages(in: thread, matching: GmailSyncPolicy(version: 1)).map(\.id) == ["wrong-label"])
  }

  @Test
  func reevaluatesMembershipAfterARequiredLabelIsRemoved() throws {
    let before = try makeThread([message("message", labels: ["Work"])])
    let after = try makeThread([message("message", labels: [])])
    let policy = try GmailSyncPolicy(version: 1, requiredLabelIds: ["Work"])

    #expect(try selector.messages(in: before, matching: policy) == before.messages)
    #expect(try selector.messages(in: after, matching: policy).isEmpty)
  }

  @Test
  func anEmptyConversationDoesNotQualify() throws {
    #expect(try selector.messages(in: makeThread([]), matching: GmailSyncPolicy(version: 1)).isEmpty)
  }

  @Test
  func selectionFailureExplainsHowToPreserveExistingMembership() throws {
    let error = GmailPolicyThreadSelector.SelectionError.invalidInternalDate

    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(try #require(error.recoverySuggestion).contains("previous membership"))
  }
}

private extension GmailPolicyThreadSelectorTests {
  func message(_ id: String, labels: [String]? = [], internalDate: String? = "2000") -> [String: Any] {
    var fields: [String: Any] = ["id": id, "threadId": "thread"]
    if let labels { fields["labelIds"] = labels }
    if let internalDate { fields["internalDate"] = internalDate }
    return fields
  }

  func makeThread(_ messages: [[String: Any]]) throws -> GmailThread {
    let data = try JSONSerialization.data(withJSONObject: ["id": "thread", "messages": messages])
    return try JSONDecoder().decode(GmailThread.self, from: data)
  }
}
