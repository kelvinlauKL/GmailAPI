import Foundation
import Testing
import GmailAPI

struct GmailMessagePartBodyTests {
  @Test(arguments: ["-_8=", "-_8"])
  func preservesInlineBase64URLContent(encodedContent: String) throws {
    let json = """
      {"size":2,"data":"\(encodedContent)","futureField":true}
      """
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == nil)
    #expect(body.size == 2)
    #expect(body.data == encodedContent)
  }

  @Test
  func preservesExternalAttachmentReferenceWithoutInlineContent() throws {
    let json = #"{"attachmentId":"opaque+/=%2F","size":1234}"#
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == "opaque+/=%2F")
    #expect(body.size == 1234)
    #expect(body.data == nil)
  }

  @Test(arguments: ["{}", #"{"attachmentId":null,"size":null,"data":null}"#])
  func preservesMissingFieldsWithoutInventingEmptyContent(json: String) throws {
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == nil)
    #expect(body.size == nil)
    #expect(body.data == nil)
  }

  @Test
  func distinguishesExplicitEmptyContentFromMissingContent() throws {
    let json = #"{"size":0,"data":""}"#
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == nil)
    #expect(body.size == 0)
    #expect(body.data == "")
  }

  @Test
  func preservesEmptyDataAlongsideAttachmentReference() throws {
    let json = #"{"attachmentId":"attachment-id","size":1234,"data":""}"#
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == "attachment-id")
    #expect(body.size == 1234)
    #expect(body.data == "")
  }

  @Test(arguments: [
    #"{"attachmentId":123}"#,
    #"{"size":"2"}"#,
    #"{"size":1.5}"#,
    #"{"size":true}"#,
    #"{"data":123}"#,
    #"{"data":[]}"#
  ])
  func rejectsIncorrectFieldTypes(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))
    }
  }
}
