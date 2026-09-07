import Foundation
import Testing
import GmailAPI

struct GmailHistoryRecordTests {
  @Test
  func decodesAllChangeTypesAndPreservesOverlappingMessages() throws {
    let json = """
      {
        "id":"18446744073709551615",
        "messages":[
          {"id":"message-2","threadId":"thread-2"},
          {"id":"message-1","threadId":"thread-1"},
          {"id":"message-3","threadId":"thread-1"}
        ],
        "messagesAdded":[
          {"message":{"id":"message-1","threadId":"thread-1"},"futureField":true},
          {"message":{"id":"message-3","threadId":"thread-1"}}
        ],
        "messagesDeleted":[{"message":{"id":"message-2","threadId":"thread-2"}}],
        "labelsAdded":[{
          "message":{"id":"message-1","threadId":"thread-1","labelIds":["INBOX","Label_1"]},
          "labelIds":["Label_1"]
        }],
        "labelsRemoved":[{
          "message":{"id":"message-1","threadId":"thread-1"},
          "labelIds":["UNREAD","STARRED"]
        }],
        "futureField":true
      }
      """
    let record = try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))
    let addedLabels = try #require(record.labelsAdded?.first)
    let removedLabels = try #require(record.labelsRemoved?.first)

    #expect(record.id == "18446744073709551615")
    #expect(record.messages?.map(\.id) == ["message-2", "message-1", "message-3"])
    #expect(record.messagesAdded?.map(\.message.id) == ["message-1", "message-3"])
    #expect(record.messagesDeleted?.map(\.message.id) == ["message-2"])
    #expect(record.messagesDeleted?.first?.message.threadId == "thread-2")
    #expect(record.messagesAdded?.first?.message.payload == nil)
    #expect(addedLabels.message.id == "message-1")
    #expect(addedLabels.message.labelIds == ["INBOX", "Label_1"])
    #expect(addedLabels.labelIds == ["Label_1"])
    #expect(removedLabels.message.id == "message-1")
    #expect(removedLabels.message.labelIds == nil)
    #expect(removedLabels.labelIds == ["UNREAD", "STARRED"])
  }

  @Test(arguments: [
    #"{"id":"123"}"#,
    """
      {"id":"123","messages":null,"messagesAdded":null,"messagesDeleted":null,
       "labelsAdded":null,"labelsRemoved":null}
      """
  ])
  func preservesMissingOrNullChangeCollections(json: String) throws {
    let record = try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))

    #expect(record.id == "123")
    #expect(record.messages == nil)
    #expect(record.messagesAdded == nil)
    #expect(record.messagesDeleted == nil)
    #expect(record.labelsAdded == nil)
    #expect(record.labelsRemoved == nil)
  }

  @Test
  func preservesExplicitEmptyChangeCollections() throws {
    let json = """
      {"id":"123","messages":[],"messagesAdded":[],"messagesDeleted":[],
       "labelsAdded":[],"labelsRemoved":[]}
      """
    let record = try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))

    #expect(record.messages == [])
    #expect(record.messagesAdded == [])
    #expect(record.messagesDeleted == [])
    #expect(record.labelsAdded == [])
    #expect(record.labelsRemoved == [])
  }

  @Test(arguments: ["{}", #"{"id":null}"#, #"{"id":123}"#, #"{"id":true}"#])
  func rejectsMissingOrNonStringRecordIdentifier(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["messages", "messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved"])
  func rejectsNonArrayChangeCollections(field: String) {
    let json = """
      {"id":"123","\(field)":{}}
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["messagesAdded", "messagesDeleted"], [
    "null", "{}", #"{"message":null}"#, #"{"message":[]}"#,
    #"{"message":{"id":"message-1"}}"#,
    #"{"message":{"threadId":"thread-1"}}"#,
    #"{"message":{"id":123,"threadId":"thread-1"}}"#
  ])
  func rejectsMalformedMessageChanges(field: String, eventJSON: String) {
    let json = """
      {"id":"123","\(field)":[\(eventJSON)]}
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["labelsAdded", "labelsRemoved"], [
    "null", #"{"labelIds":["INBOX"]}"#,
    #"{"message":null,"labelIds":["INBOX"]}"#,
    #"{"message":{"id":"message-1","threadId":"thread-1"}}"#,
    #"{"message":{"id":"message-1","threadId":"thread-1"},"labelIds":null}"#,
    #"{"message":{"id":"message-1","threadId":"thread-1"},"labelIds":"INBOX"}"#,
    #"{"message":{"id":"message-1","threadId":"thread-1"},"labelIds":[123]}"#
  ])
  func rejectsMalformedLabelChanges(field: String, eventJSON: String) {
    let json = """
      {"id":"123","\(field)":[\(eventJSON)]}
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryRecord.self, from: Data(json.utf8))
    }
  }
}
