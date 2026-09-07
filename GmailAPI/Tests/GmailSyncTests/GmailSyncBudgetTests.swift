import Foundation
import Testing
import GmailSync

struct GmailSyncBudgetTests {
  @Test
  func suppliesDefaultPassLimits() throws {
    let budget = try GmailSyncBudget()

    #expect(budget.maximumDiscoveryPages == 10)
    #expect(budget.maximumThreadFetches == 100)
    #expect(budget.maximumConcurrentThreadFetches == 4)
  }

  @Test
  func acceptsIndependentPositiveLimits() throws {
    let budget = try GmailSyncBudget(
      maximumDiscoveryPages: 1, maximumThreadFetches: 2, maximumConcurrentThreadFetches: 4
    )

    #expect(budget.maximumDiscoveryPages == 1)
    #expect(budget.maximumThreadFetches == 2)
    #expect(budget.maximumConcurrentThreadFetches == 4)
    #expect(try GmailSyncBudget(maximumDiscoveryPages: Int.max).maximumDiscoveryPages == Int.max)
  }

  @Test(arguments: [0, -1, Int.min])
  func rejectsNonpositiveDiscoveryLimits(limit: Int) {
    #expect(throws: GmailSyncBudget.ValidationError.invalidDiscoveryPageLimit(limit)) {
      try GmailSyncBudget(maximumDiscoveryPages: limit)
    }
  }

  @Test(arguments: [0, -1, Int.min])
  func rejectsNonpositiveFetchLimits(limit: Int) {
    #expect(throws: GmailSyncBudget.ValidationError.invalidThreadFetchLimit(limit)) {
      try GmailSyncBudget(maximumThreadFetches: limit)
    }
  }

  @Test(arguments: [0, -1, Int.min])
  func rejectsNonpositiveConcurrencyLimits(limit: Int) {
    #expect(throws: GmailSyncBudget.ValidationError.invalidConcurrencyLimit(limit)) {
      try GmailSyncBudget(maximumConcurrentThreadFetches: limit)
    }
  }

  @Test
  func persistsEveryLimit() throws {
    let budget = try GmailSyncBudget(
      maximumDiscoveryPages: 2, maximumThreadFetches: 30, maximumConcurrentThreadFetches: 3
    )
    let data = try JSONEncoder().encode(budget)
    let fields = try JSONDecoder().decode([String: Int].self, from: data)

    #expect(fields == ["maximumDiscoveryPages": 2, "maximumThreadFetches": 30, "maximumConcurrentThreadFetches": 3])
    #expect(try JSONDecoder().decode(GmailSyncBudget.self, from: data) == budget)
  }

  @Test(arguments: [
    ("maximumDiscoveryPages", GmailSyncBudget.ValidationError.invalidDiscoveryPageLimit(0)),
    ("maximumThreadFetches", .invalidThreadFetchLimit(0)),
    ("maximumConcurrentThreadFetches", .invalidConcurrencyLimit(0))
  ])
  func decodingCannotBypassValidation(field: String, expectedError: GmailSyncBudget.ValidationError) throws {
    var fields = ["maximumDiscoveryPages": 2, "maximumThreadFetches": 30, "maximumConcurrentThreadFetches": 3]
    fields[field] = 0
    let data = try JSONEncoder().encode(fields)

    #expect(throws: expectedError) { try JSONDecoder().decode(GmailSyncBudget.self, from: data) }
  }

  @Test(arguments: [
    "{}", #"{"maximumDiscoveryPages":2,"maximumThreadFetches":30}"#,
    #"{"maximumDiscoveryPages":2,"maximumThreadFetches":30,"maximumConcurrentThreadFetches":null}"#,
    #"{"maximumDiscoveryPages":2,"maximumThreadFetches":30,"maximumConcurrentThreadFetches":"3"}"#
  ])
  func rejectsIncompleteOrMistypedPersistedLimits(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailSyncBudget.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    GmailSyncBudget.ValidationError.invalidDiscoveryPageLimit(0),
    .invalidThreadFetchLimit(0), .invalidConcurrencyLimit(0)
  ])
  func explainsHowToCorrectInvalidLimits(error: GmailSyncBudget.ValidationError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}
