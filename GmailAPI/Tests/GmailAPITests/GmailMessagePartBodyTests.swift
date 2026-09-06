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
    #expect(try body.decodedData() == nil)
  }

  @Test(arguments: ["{}", #"{"attachmentId":null,"size":null,"data":null}"#])
  func preservesMissingFieldsWithoutInventingEmptyContent(json: String) throws {
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == nil)
    #expect(body.size == nil)
    #expect(body.data == nil)
    #expect(try body.decodedData() == nil)
  }

  @Test
  func distinguishesExplicitEmptyContentFromMissingContent() throws {
    let json = #"{"size":0,"data":""}"#
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == nil)
    #expect(body.size == 0)
    #expect(body.data == "")
    #expect(try body.decodedData() == Data())
  }

  @Test
  func preservesEmptyDataAlongsideAttachmentReference() throws {
    let json = #"{"attachmentId":"attachment-id","size":1234,"data":""}"#
    let body = try JSONDecoder().decode(GmailMessagePartBody.self, from: Data(json.utf8))

    #expect(body.attachmentId == "attachment-id")
    #expect(body.size == 1234)
    #expect(body.data == "")
    #expect(try body.decodedData() == Data())
  }

  @Test(arguments: [
    ("Zg==", "f"), ("Zg", "f"),
    ("Zm8=", "fo"), ("Zm8", "fo"), ("Zm9v", "foo"),
    ("Zm9vYg==", "foob"), ("Zm9vYg", "foob"),
    ("Zm9vYmE=", "fooba"), ("Zm9vYmE", "fooba"),
    ("Zm9vYmFy", "foobar"), ("6Zuq", "雪")
  ])
  func decodesPaddedAndUnpaddedContent(encodedContent: String, expectedText: String) throws {
    let body = try bodyWithContent(encodedContent)

    #expect(try body.decodedData() == Data(expectedText.utf8))
    #expect(body.data == encodedContent)
  }

  @Test(arguments: ["-_8=", "-_8"])
  func decodesBinaryContentWithoutInterpretingText(encodedContent: String) throws {
    let body = try bodyWithContent(encodedContent)

    #expect(try body.decodedData() == Data([0xfb, 0xff]))
    #expect(body.data == encodedContent)
  }

  @Test(arguments: [
    "A", "abcde", "++8=", "//8=", "Zg%3D%3D", "Z g==", "Zg==\n", "雪",
    "Zg=", "Zg===", "====", "AA=A", "Z=g=", "AAAA=", "Zg==AAAA"
  ])
  func rejectsMalformedBase64URLContent(encodedContent: String) throws {
    let body = try bodyWithContent(encodedContent)

    #expect(throws: GmailMessagePartBody.ContentDecodingError.invalidBase64URL) {
      try body.decodedData()
    }
    #expect(body.data == encodedContent)
  }

  @Test
  func decodingFailureDoesNotExposeBodyContent() throws {
    let privateContent = "private-email-content!"
    let body = try bodyWithContent(privateContent)

    do {
      _ = try body.decodedData()
      Issue.record("Expected a body decoding failure.")
    } catch let error as GmailMessagePartBody.ContentDecodingError {
      #expect(error == .invalidBase64URL)
      let failureReason = try #require(error.failureReason)
      let recoverySuggestion = try #require(error.recoverySuggestion)
      #expect(!error.localizedDescription.contains(privateContent))
      #expect(!failureReason.contains(privateContent))
      #expect(!recoverySuggestion.contains(privateContent))
    }
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

  private func bodyWithContent(_ encodedContent: String) throws -> GmailMessagePartBody {
    let json = try JSONEncoder().encode(["data": encodedContent])
    return try JSONDecoder().decode(GmailMessagePartBody.self, from: json)
  }
}
