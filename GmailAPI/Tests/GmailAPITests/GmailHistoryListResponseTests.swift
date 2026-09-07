import Foundation
import Testing
import GmailAPI

struct GmailHistoryListResponseTests {
  @Test
  func decodesPageAndPreservesHistoryOrder() throws {
    let json = """
      {
        "history": [
          {
            "id":"100",
            "messagesAdded":[{"message":{"id":"message-1","threadId":"thread-1"}}]
          },
          {"id":"104"}
        ],
        "nextPageToken":"opaque+/=token",
        "historyId":"18446744073709551615",
        "futureField":true
      }
      """
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))
    let history = try #require(response.history)

    #expect(history.map(\.id) == ["100", "104"])
    #expect(history.first?.messagesAdded?.first?.message.id == "message-1")
    #expect(history.first?.messagesAdded?.first?.message.threadId == "thread-1")
    #expect(response.nextPageToken == "opaque+/=token")
    #expect(response.historyId == "18446744073709551615")
  }

  @Test(arguments: [
    #"{"historyId":"123"}"#,
    #"{"history":null,"nextPageToken":null,"historyId":"123"}"#
  ])
  func preservesMissingOrNullOptionalFields(json: String) throws {
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))

    #expect(response.history == nil)
    #expect(response.nextPageToken == nil)
    #expect(response.historyId == "123")
  }

  @Test
  func decodesEmptyFinalPage() throws {
    let json = #"{"history":[],"historyId":"123"}"#
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))

    #expect(response.history == [])
    #expect(response.nextPageToken == nil)
    #expect(response.historyId == "123")
  }

  @Test(arguments: [
    #"{"nextPageToken":"next-page","historyId":"123"}"#,
    #"{"history":null,"nextPageToken":"next-page","historyId":"123"}"#,
    #"{"history":[],"nextPageToken":"next-page","historyId":"123"}"#
  ])
  func preservesNextPageTokenWhenNoRecordsArePresent(json: String) throws {
    let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))

    #expect(response.history?.isEmpty ?? true)
    #expect(response.nextPageToken == "next-page")
    #expect(response.historyId == "123")
  }

  @Test(arguments: [
    "{}", #"{"historyId":null}"#, #"{"historyId":123}"#, #"{"historyId":true}"#,
    #"{"history":[{"id":"123"}]}"#
  ])
  func rejectsMissingOrNonStringMailboxHistoryID(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    #"{"history":{},"historyId":"123"}"#,
    #"{"history":[null],"historyId":"123"}"#,
    #"{"history":[{}],"historyId":"123"}"#,
    #"{"history":[{"id":100}],"historyId":"123"}"#,
    #"{"history":[{"id":"100","messagesAdded":[{}]}],"historyId":"123"}"#,
    #"{"nextPageToken":123,"historyId":"123"}"#,
    #"{"nextPageToken":false,"historyId":"123"}"#
  ])
  func rejectsMalformedResponse(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailHistoryListResponse.self, from: Data(json.utf8))
    }
  }
}
