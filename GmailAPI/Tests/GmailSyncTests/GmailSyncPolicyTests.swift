import Foundation
import Testing
import GmailSync

struct GmailSyncPolicyTests {
  @Test
  func defaultsToAllDatesAndLabelsWithDraftsSpamAndTrashExcluded() throws {
    let policy = try GmailSyncPolicy(version: 1)

    #expect(policy.version == 1)
    #expect(policy.oldestMessageDate == nil)
    #expect(policy.requiredLabelIds.isEmpty)
    #expect(!policy.includeSpamTrash)
    #expect(!policy.includeDrafts)
  }

  @Test
  func preservesFixedSelectionSettings() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let policy = try GmailSyncPolicy(
      version: 2, oldestMessageDate: date, requiredLabelIds: ["Work", "INBOX"],
      includeSpamTrash: true, includeDrafts: true
    )

    #expect(policy.version == 2)
    #expect(policy.oldestMessageDate == date)
    #expect(policy.requiredLabelIds == ["INBOX", "Work"])
    #expect(policy.includeSpamTrash)
    #expect(policy.includeDrafts)
    #expect(try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: -1)).oldestMessageDate != nil)
  }

  @Test
  func treatsLabelOrderAndDuplicatesAsTheSameSelection() throws {
    let first = try GmailSyncPolicy(version: 1, requiredLabelIds: ["Work", "INBOX", "Work"])
    let second = try GmailSyncPolicy(version: 1, requiredLabelIds: ["INBOX", "Work"])

    #expect(first == second)
    let data = try JSONEncoder().encode(first)
    let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["requiredLabelIds"] as? [String] == ["INBOX", "Work"])
  }

  @Test
  func preservesOpaqueLabelValues() throws {
    let labels = ["000Label+/=%2F", " INBOX ", "inbox", "INBOX"]
    let policy = try GmailSyncPolicy(version: 1, requiredLabelIds: labels)

    #expect(Set(policy.requiredLabelIds) == Set(labels))
    #expect(policy.requiredLabelIds.count == labels.count)
  }

  @Test(arguments: [0, -1, Int.min])
  func rejectsNonpositiveVersions(version: Int) {
    #expect(throws: GmailSyncPolicy.ValidationError.invalidVersion(version)) {
      try GmailSyncPolicy(version: version)
    }
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func rejectsNonfiniteDates(interval: TimeInterval) {
    #expect(throws: GmailSyncPolicy.ValidationError.invalidOldestMessageDate) {
      try GmailSyncPolicy(version: 1, oldestMessageDate: Date(timeIntervalSince1970: interval))
    }
  }

  @Test(arguments: ["", " ", "\t\n\r"])
  func rejectsBlankRequiredLabelIDs(labelID: String) {
    #expect(throws: GmailSyncPolicy.ValidationError.emptyRequiredLabelID) {
      try GmailSyncPolicy(version: 1, requiredLabelIds: ["INBOX", labelID])
    }
  }

  @Test
  func persistsEverySelectionSettingUsingTheConfiguredDateStrategy() throws {
    let policy = try GmailSyncPolicy(
      version: 3, oldestMessageDate: Date(timeIntervalSince1970: 1_700_000_000),
      requiredLabelIds: ["Work", "INBOX"], includeSpamTrash: true, includeDrafts: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(policy)
    let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(fields["oldestMessageDate"] as? Double == 1_700_000_000_000)
    #expect(try decoder.decode(GmailSyncPolicy.self, from: data) == policy)
    let defaultPolicy = try GmailSyncPolicy(version: 1)
    #expect(try decoder.decode(GmailSyncPolicy.self, from: encoder.encode(defaultPolicy)) == defaultPolicy)
  }

  @Test
  func canonicalizesPersistedLabelIDs() throws {
    let json = #"{"version":1,"requiredLabelIds":["Work","INBOX","Work"],"includeSpamTrash":false,"includeDrafts":false}"#
    let policy = try JSONDecoder().decode(GmailSyncPolicy.self, from: Data(json.utf8))
    let expectedPolicy = try GmailSyncPolicy(version: 1, requiredLabelIds: ["INBOX", "Work"])

    #expect(policy == expectedPolicy)
  }

  @Test(arguments: [
    (#"{"version":0,"requiredLabelIds":[],"includeSpamTrash":false,"includeDrafts":false}"#,
      GmailSyncPolicy.ValidationError.invalidVersion(0)),
    (#"{"version":1,"requiredLabelIds":[""],"includeSpamTrash":false,"includeDrafts":false}"#, .emptyRequiredLabelID),
    (#"{"version":1,"oldestMessageDate":"NaN","requiredLabelIds":[],"includeSpamTrash":false,"includeDrafts":false}"#,
      .invalidOldestMessageDate)
  ])
  func decodingCannotBypassValidation(json: String, expectedError: GmailSyncPolicy.ValidationError) {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
    )

    #expect(throws: expectedError) { try decoder.decode(GmailSyncPolicy.self, from: Data(json.utf8)) }
  }

  @Test(arguments: [
    "{}", #"{"version":1}"#,
    #"{"version":1,"requiredLabelIds":null,"includeSpamTrash":false,"includeDrafts":false}"#,
    #"{"version":1,"requiredLabelIds":[],"includeSpamTrash":"false","includeDrafts":false}"#
  ])
  func rejectsIncompleteOrMistypedPersistedSettings(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailSyncPolicy.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    GmailSyncPolicy.ValidationError.invalidVersion(0), .invalidOldestMessageDate, .emptyRequiredLabelID
  ])
  func explainsHowToCorrectInvalidSettings(error: GmailSyncPolicy.ValidationError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}
