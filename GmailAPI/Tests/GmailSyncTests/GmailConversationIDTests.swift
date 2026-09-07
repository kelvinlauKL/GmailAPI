import Foundation
import Testing
import GmailSync

struct GmailConversationIDTests {
  @Test
  func distinguishesConversationsByBothAccountAndThread() throws {
    let original = try GmailConversationID(accountID: "account-one", threadID: "same-thread")
    let otherAccount = try GmailConversationID(accountID: "account-two", threadID: "same-thread")
    let otherThread = try GmailConversationID(accountID: "account-one", threadID: "other-thread")
    let duplicate = try GmailConversationID(accountID: "account-one", threadID: "same-thread")

    #expect(original != otherAccount)
    #expect(original != otherThread)
    #expect(original == duplicate)
    #expect(Set([original, otherAccount, otherThread, duplicate]).count == 3)
    let revisions = [original: 1, otherAccount: 2]
    #expect(revisions[original] == 1)
    #expect(revisions[otherAccount] == 2)
  }

  @Test
  func preservesOpaqueIdentifiersAndComponentBoundaries() throws {
    let identifier = try GmailConversationID(accountID: " Account/One ", threadID: "000AbC+/=%2F")
    let first = try GmailConversationID(accountID: "a/b", threadID: "c")
    let second = try GmailConversationID(accountID: "a", threadID: "b/c")
    let differentCase = try GmailConversationID(accountID: " Account/One ", threadID: "000abc+/=%2F")

    #expect(identifier.accountID == " Account/One ")
    #expect(identifier.threadID == "000AbC+/=%2F")
    #expect(first != second)
    #expect(identifier != differentCase)
  }

  @Test(arguments: ["", " ", "\t\n\r"])
  func rejectsBlankAccountIDs(accountID: String) {
    #expect(throws: GmailConversationID.ValidationError.emptyAccountID) {
      try GmailConversationID(accountID: accountID, threadID: "thread")
    }
  }

  @Test(arguments: ["", " ", "\t\n\r"])
  func rejectsBlankThreadIDs(threadID: String) {
    #expect(throws: GmailConversationID.ValidationError.emptyThreadID) {
      try GmailConversationID(accountID: "account", threadID: threadID)
    }
  }

  @Test
  func persistsBothFieldsWithoutCombiningThem() throws {
    let identifier = try GmailConversationID(accountID: "account/one", threadID: "000ABC")
    let data = try JSONEncoder().encode(identifier)
    let fields = try JSONDecoder().decode([String: String].self, from: data)

    #expect(fields == ["accountID": "account/one", "threadID": "000ABC"])
    #expect(try JSONDecoder().decode(GmailConversationID.self, from: data) == identifier)
  }

  @Test(arguments: [
    (#"{"accountID":"","threadID":"thread"}"#, GmailConversationID.ValidationError.emptyAccountID),
    (#"{"accountID":"account","threadID":" \t"}"#, .emptyThreadID)
  ])
  func decodingCannotBypassValidation(json: String, expectedError: GmailConversationID.ValidationError) {
    #expect(throws: expectedError) {
      try JSONDecoder().decode(GmailConversationID.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    "{}", #"{"accountID":"account"}"#, #"{"threadID":"thread"}"#,
    #"{"accountID":null,"threadID":"thread"}"#, #"{"accountID":"account","threadID":123}"#
  ])
  func rejectsIncompleteOrMistypedPersistedKeys(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailConversationID.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [GmailConversationID.ValidationError.emptyAccountID, .emptyThreadID])
  func explainsHowToCorrectInvalidKeys(error: GmailConversationID.ValidationError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }
}
