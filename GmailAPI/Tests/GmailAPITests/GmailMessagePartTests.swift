import Foundation
import Testing
import GmailAPI

struct GmailMessagePartTests {
  @Test
  func decodesTextPartAndIgnoresUnknownFields() throws {
    let json = """
      {
        "partId":"0", "mimeType":"text/plain", "filename":"",
        "headers":[{"name":"Content-Type","value":"text/plain; charset=UTF-8"}],
        "body":{"size":5,"data":"SGVsbG8="}, "futureField":true
      }
      """
    let part = try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))

    #expect(part.partId == "0")
    #expect(part.mimeType == "text/plain")
    #expect(part.filename == "")
    #expect(part.headers?.first?.name == "Content-Type")
    #expect(part.headers?.first?.value == "text/plain; charset=UTF-8")
    #expect(part.body?.size == 5)
    #expect(part.body?.data == "SGVsbG8=")
    #expect(part.body?.attachmentId == nil)
    #expect(part.parts == nil)
  }

  @Test
  func preservesNestedMultipartContentAndAttachmentOrder() throws {
    let json = """
      {
        "partId":"", "mimeType":"multipart/mixed", "body":{"size":0,"data":""},
        "parts":[
          {
            "partId":"0", "mimeType":"multipart/alternative", "body":{},
            "parts":[
              {"partId":"0.0","mimeType":"text/plain","body":{"size":5,"data":"SGVsbG8="}},
              {"partId":"0.1","mimeType":"text/html","body":{"size":12,"data":"PHA-SGVsbG88L3A-"}}
            ]
          },
          {
            "partId":"1", "mimeType":"application/pdf", "filename":"invoice-雪.pdf",
            "body":{"attachmentId":"opaque+/=%2F","size":1234}
          }
        ]
      }
      """
    let part = try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))
    let children = try #require(part.parts)
    let alternative = try #require(children.first)
    let alternatives = try #require(alternative.parts)
    let attachment = try #require(children.last)

    #expect(part.partId == "")
    #expect(part.mimeType == "multipart/mixed")
    #expect(part.body?.size == 0)
    #expect(children.map(\.partId) == ["0", "1"])
    #expect(alternative.mimeType == "multipart/alternative")
    #expect(alternatives.map(\.partId) == ["0.0", "0.1"])
    #expect(alternatives.map(\.mimeType) == ["text/plain", "text/html"])
    #expect(alternatives.first?.body?.data == "SGVsbG8=")
    #expect(alternatives.last?.body?.data == "PHA-SGVsbG88L3A-")
    #expect(attachment.mimeType == "application/pdf")
    #expect(attachment.filename == "invoice-雪.pdf")
    #expect(attachment.body?.attachmentId == "opaque+/=%2F")
    #expect(attachment.body?.size == 1234)
    #expect(attachment.body?.data == nil)
    #expect(attachment.parts == nil)
  }

  @Test
  func preservesHeaderOrderDuplicateNamesAndOriginalValues() throws {
    let json = """
      {"headers":[
        {"name":"Received","value":"first hop"},
        {"name":"Received","value":"second hop"},
        {"name":"received","value":"third hop"},
        {"name":"Subject","value":"=?UTF-8?B?SGVsbG8=?="},
        {"name":"X-Empty","value":""}
      ]}
      """
    let part = try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))
    let headers = try #require(part.headers)

    #expect(headers.map(\.name) == ["Received", "Received", "received", "Subject", "X-Empty"])
    #expect(headers.map(\.value) == ["first hop", "second hop", "third hop", "=?UTF-8?B?SGVsbG8=?=", ""])
  }

  @Test(arguments: [
    "{}",
    #"{"partId":null,"mimeType":null,"filename":null,"headers":null,"body":null,"parts":null}"#
  ])
  func preservesOmittedOrNullFields(json: String) throws {
    let part = try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))

    #expect(part.partId == nil)
    #expect(part.mimeType == nil)
    #expect(part.filename == nil)
    #expect(part.headers == nil)
    #expect(part.body == nil)
    #expect(part.parts == nil)
  }

  @Test
  func preservesExplicitEmptyFields() throws {
    let json = #"{"partId":"","filename":"","headers":[],"body":{},"parts":[]}"#
    let part = try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))
    let body = try #require(part.body)

    #expect(part.partId == "")
    #expect(part.filename == "")
    #expect(part.headers == [])
    #expect(part.parts == [])
    #expect(body.size == nil)
    #expect(body.data == nil)
    #expect(body.attachmentId == nil)
  }

  @Test(arguments: [
    #"{"partId":123}"#,
    #"{"mimeType":123}"#,
    #"{"filename":[]}"#,
    #"{"headers":{}}"#,
    #"{"body":[]}"#,
    #"{"body":{"data":123}}"#,
    #"{"parts":{}}"#,
    #"{"parts":[{"mimeType":123}]}"#
  ])
  func rejectsIncorrectPartFieldTypes(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    #"{}"#,
    #"{"name":"Subject"}"#,
    #"{"value":"Hello"}"#,
    #"{"name":null,"value":"Hello"}"#,
    #"{"name":"Subject","value":null}"#,
    #"{"name":123,"value":"Hello"}"#,
    #"{"name":"Subject","value":123}"#
  ])
  func rejectsMalformedHeaderEntries(headerJSON: String) {
    let json = "{\"headers\":[\(headerJSON)]}"

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailMessagePart.self, from: Data(json.utf8))
    }
  }
}
