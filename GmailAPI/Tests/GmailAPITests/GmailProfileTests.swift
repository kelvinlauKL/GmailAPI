import Foundation
import Testing
import GmailAPI

struct GmailProfileTests {
  @Test
  func decodesProfileAndIgnoresUnknownFields() throws {
    let data = Data("""
      {
        "emailAddress": "demo@example.com",
        "messagesTotal": 50000,
        "threadsTotal": 12000,
        "historyId": "18446744073709551615",
        "futureField": true
      }
      """.utf8)

    let profile = try JSONDecoder().decode(GmailProfile.self, from: data)

    #expect(profile.emailAddress == "demo@example.com")
    #expect(profile.messagesTotal == 50000)
    #expect(profile.threadsTotal == 12000)
    #expect(profile.historyId == "18446744073709551615")
  }

  @Test
  func decodesEmptyMailbox() throws {
    let data = Data("""
      {
        "emailAddress": "demo@example.com",
        "messagesTotal": 0,
        "threadsTotal": 0,
        "historyId": "1"
      }
      """.utf8)

    let profile = try JSONDecoder().decode(GmailProfile.self, from: data)

    #expect(profile.messagesTotal == 0)
    #expect(profile.threadsTotal == 0)
    #expect(profile.historyId == "1")
  }

  @Test(arguments: ["", ",\"historyId\":null", ",\"historyId\":123"])
  func rejectsMissingOrNonStringHistoryCursor(cursorField: String) {
    let data = Data("""
      {
        "emailAddress": "demo@example.com",
        "messagesTotal": 0,
        "threadsTotal": 0
        \(cursorField)
      }
      """.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailProfile.self, from: data)
    }
  }
}
