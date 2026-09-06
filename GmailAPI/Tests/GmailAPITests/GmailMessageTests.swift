import Foundation
import Testing
import GmailAPI

struct GmailMessageTests {
  @Test
  func decodesMessageMetadataAndMIMEPayload() throws {
    let json = """
      {
        "id":"message-1", "threadId":"thread-1", "labelIds":["INBOX","UNREAD"],
        "snippet":"Hello", "historyId":"18446744073709551615",
        "internalDate":"1700000000123", "sizeEstimate":1234,
        "payload":{
          "partId":"", "mimeType":"multipart/mixed",
          "headers":[{"name":"Subject","value":"Hello"}],
          "body":{"size":0},
          "parts":[
            {"partId":"0","mimeType":"text/plain","body":{"size":5,"data":"SGVsbG8="}},
            {"partId":"1","filename":"report.pdf","body":{"attachmentId":"attachment-1","size":1000}}
          ]
        },
        "futureField":true
      }
      """
    let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    let payload = try #require(message.payload)

    #expect(message.id == "message-1")
    #expect(message.threadId == "thread-1")
    #expect(message.labelIds == ["INBOX", "UNREAD"])
    #expect(message.snippet == "Hello")
    #expect(message.historyId == "18446744073709551615")
    #expect(message.internalDate == "1700000000123")
    #expect(message.sizeEstimate == 1234)
    #expect(message.raw == nil)
    #expect(payload.mimeType == "multipart/mixed")
    #expect(payload.headers?.first?.name == "Subject")
    #expect(payload.headers?.first?.value == "Hello")
    #expect(payload.parts?.map(\.partId) == ["0", "1"])
    #expect(payload.parts?.first?.body?.data == "SGVsbG8=")
    #expect(payload.parts?.last?.filename == "report.pdf")
    #expect(payload.parts?.last?.body?.attachmentId == "attachment-1")
  }

  @Test(arguments: [
    #"{"id":"message-1","threadId":"thread-1"}"#,
    """
      {"id":"message-1","threadId":"thread-1","labelIds":null,"snippet":null,
       "historyId":null,"internalDate":null,"payload":null,"sizeEstimate":null,"raw":null}
      """
  ])
  func preservesOmittedOrNullMetadata(json: String) throws {
    let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))

    #expect(message.id == "message-1")
    #expect(message.threadId == "thread-1")
    #expect(message.labelIds == nil)
    #expect(message.snippet == nil)
    #expect(message.historyId == nil)
    #expect(message.internalDate == nil)
    #expect(message.payload == nil)
    #expect(message.sizeEstimate == nil)
    #expect(message.raw == nil)
  }

  @Test
  func preservesExplicitEmptyMetadata() throws {
    let json = """
      {"id":"message-1","threadId":"thread-1","labelIds":[],"snippet":"",
       "payload":{},"sizeEstimate":0,"raw":""}
      """
    let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    let payload = try #require(message.payload)

    #expect(message.labelIds == [])
    #expect(message.snippet == "")
    #expect(message.sizeEstimate == 0)
    #expect(message.raw == "")
    #expect(payload.mimeType == nil)
    #expect(payload.body == nil)
    #expect(payload.parts == nil)
  }

  @Test(arguments: ["U3ViamVjdDogVGVzdA0KDQpIZWxsbw==", "U3ViamVjdDogVGVzdA0KDQpIZWxsbw"])
  func preservesRawMessageWithoutRequiringParsedPayload(encodedMessage: String) throws {
    let json = """
      {"id":"message-1","threadId":"thread-1","raw":"\(encodedMessage)"}
      """
    let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))

    #expect(message.raw == encodedMessage)
    #expect(message.payload == nil)
  }

  @Test(arguments: [
    "{}",
    #"{"threadId":"thread-1"}"#,
    #"{"id":"message-1"}"#,
    #"{"id":null,"threadId":"thread-1"}"#,
    #"{"id":123,"threadId":"thread-1"}"#,
    #"{"id":"message-1","threadId":null}"#,
    #"{"id":"message-1","threadId":123}"#
  ])
  func rejectsMissingOrNonStringIdentifiers(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    #""labelIds":"INBOX""#,
    #""labelIds":[123]"#,
    #""snippet":123"#,
    #""historyId":123"#,
    #""internalDate":1700000000123"#,
    #""payload":[]"#,
    #""payload":{"headers":[{"name":"Subject"}]}"#,
    #""sizeEstimate":"1234""#,
    #""raw":123"#
  ])
  func rejectsIncorrectMetadataTypes(field: String) {
    let json = "{\"id\":\"message-1\",\"threadId\":\"thread-1\",\(field)}"

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }
  }
}
