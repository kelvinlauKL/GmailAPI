import Foundation
import Testing
import GmailAPI

struct GmailThreadListResponseTests {
  @Test
  func decodesPageAndPreservesThreadOrder() throws {
    let data = Data("""
      {
        "threads": [
          {"id":"18abc123","snippet":"Elevator repair","historyId":"100"},
          {"id":"18def456"}
        ],
        "nextPageToken": "opaque+/=token",
        "resultSizeEstimate": 50,
        "futureField": true
      }
      """.utf8)

    let page = try JSONDecoder().decode(GmailThreadListResponse.self, from: data)
    let threads = try #require(page.threads)

    #expect(threads.map(\.id) == ["18abc123", "18def456"])
    #expect(threads.first?.snippet == "Elevator repair")
    #expect(threads.first?.historyId == "100")
    #expect(page.nextPageToken == "opaque+/=token")
    #expect(page.resultSizeEstimate == 50)
  }

  @Test(arguments: [
    #"{}"#,
    #"{"threads":null,"nextPageToken":null,"resultSizeEstimate":null}"#
  ])
  func decodesOmittedOrNullFields(json: String) throws {
    let page = try JSONDecoder().decode(
      GmailThreadListResponse.self,
      from: Data(json.utf8)
    )

    #expect(page.threads == nil)
    #expect(page.nextPageToken == nil)
    #expect(page.resultSizeEstimate == nil)
  }

  @Test
  func decodesEmptyFinalPage() throws {
    let data = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
    let page = try JSONDecoder().decode(GmailThreadListResponse.self, from: data)

    #expect(page.threads == [])
    #expect(page.nextPageToken == nil)
    #expect(page.resultSizeEstimate == 0)
  }

  @Test(arguments: [
    #"{"threads":{}}"#,
    #"{"threads":[{}]}"#,
    #"{"nextPageToken":123}"#,
    #"{"resultSizeEstimate":-1}"#,
    #"{"resultSizeEstimate":4294967296}"#
  ])
  func rejectsMalformedResponse(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailThreadListResponse.self, from: Data(json.utf8))
    }
  }
}
