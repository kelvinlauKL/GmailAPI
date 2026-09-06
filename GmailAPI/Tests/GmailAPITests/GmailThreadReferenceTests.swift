import Foundation
import Testing
import GmailAPI

struct GmailThreadReferenceTests {
  @Test
  func decodesListingMetadataAndIgnoresUnknownFields() throws {
    let data = Data("""
      {
        "id": "18abc123",
        "snippet": "The elevator repair is scheduled for Monday.",
        "historyId": "18446744073709551615",
        "futureField": true
      }
      """.utf8)

    let thread = try JSONDecoder().decode(GmailThreadReference.self, from: data)

    #expect(thread.id == "18abc123")
    #expect(thread.snippet == "The elevator repair is scheduled for Monday.")
    #expect(thread.historyId == "18446744073709551615")
  }

  @Test(arguments: [
    #"{"id":"18abc123"}"#,
    #"{"id":"18abc123","snippet":null,"historyId":null}"#
  ])
  func decodesWithoutMetadata(json: String) throws {
    let thread = try JSONDecoder().decode(
      GmailThreadReference.self,
      from: Data(json.utf8)
    )

    #expect(thread.id == "18abc123")
    #expect(thread.snippet == nil)
    #expect(thread.historyId == nil)
  }

  @Test(arguments: [#"{}"#, #"{"id":null}"#, #"{"id":123}"#])
  func rejectsMissingOrNonStringIdentifier(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThreadReference.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["snippet", "historyId"])
  func rejectsNonStringMetadata(field: String) {
    let data = Data("""
      {"id":"18abc123","\(field)":123}
      """.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThreadReference.self, from: data)
    }
  }
}
