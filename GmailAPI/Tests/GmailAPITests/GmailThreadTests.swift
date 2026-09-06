import Foundation
import Testing
import GmailAPI

struct GmailThreadTests {
  @Test
  func decodesConversationAndPreservesMessageOrder() throws {
    let json = """
      {
        "id":"thread-1", "snippet":"Repair confirmed.",
        "historyId":"18446744073709551615",
        "messages":[
          {
            "id":"message-2", "threadId":"thread-1", "historyId":"100",
            "labelIds":["INBOX"], "internalDate":"1700000000123",
            "payload":{
              "mimeType":"text/plain",
              "headers":[{"name":"Subject","value":"Repair update"}],
              "body":{"size":5,"data":"SGVsbG8="}
            }
          },
          {"id":"message-1","threadId":"thread-1","internalDate":"1700000000456"}
        ],
        "futureField":true
      }
      """
    let thread = try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
    let firstMessage = try #require(thread.messages.first)

    #expect(thread.id == "thread-1")
    #expect(thread.snippet == "Repair confirmed.")
    #expect(thread.historyId == "18446744073709551615")
    #expect(thread.messages.map(\.id) == ["message-2", "message-1"])
    #expect(thread.messages.map(\.threadId) == ["thread-1", "thread-1"])
    #expect(firstMessage.historyId == "100")
    #expect(firstMessage.labelIds == ["INBOX"])
    #expect(firstMessage.internalDate == "1700000000123")
    #expect(firstMessage.payload?.headers?.first?.value == "Repair update")
    #expect(firstMessage.payload?.body?.data == "SGVsbG8=")
  }

  @Test(arguments: [
    #"{"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1"}]}"#,
    """
      {"id":"thread-1","snippet":null,"historyId":null,
       "messages":[{"id":"message-1","threadId":"thread-1"}]}
      """
  ])
  func decodesWithoutOptionalMetadata(json: String) throws {
    let thread = try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))

    #expect(thread.snippet == nil)
    #expect(thread.historyId == nil)
    #expect(thread.messages.map(\.id) == ["message-1"])
    #expect(thread.messages.first?.payload == nil)
  }

  @Test
  func preservesExplicitEmptyValues() throws {
    let json = #"{"id":"thread-1","snippet":"","historyId":"","messages":[]}"#
    let thread = try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))

    #expect(thread.snippet == "")
    #expect(thread.historyId == "")
    #expect(thread.messages.isEmpty)
  }

  @Test(arguments: [
    #"{"messages":[]}"#,
    #"{"id":null,"messages":[]}"#,
    #"{"id":123,"messages":[]}"#,
    #"{"id":"thread-1"}"#,
    #"{"id":"thread-1","messages":null}"#,
    #"{"id":"thread-1","messages":{}}"#
  ])
  func rejectsMissingOrInvalidRequiredFields(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["snippet", "historyId"])
  func rejectsNonStringMetadata(field: String) {
    let json = """
      {"id":"thread-1","messages":[],"\(field)":123}
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    "null",
    "123",
    #"{"threadId":"thread-1"}"#,
    #"{"id":"message-1"}"#,
    #"{"id":"message-1","threadId":123}"#,
    #"{"id":"message-1","threadId":"thread-1","payload":{"body":{"size":"five"}}}"#
  ])
  func rejectsMalformedMessages(messageJSON: String) {
    let json = """
      {"id":"thread-1","messages":[\(messageJSON)]}
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
    }
  }
}
