import Foundation
import Testing
@testable import GmailAPI

struct GmailThreadListRequestTests {
  @Test
  func defaultsToFirstPageWithoutFilters() throws {
    let request = try GmailThreadListRequest()

    #expect(request.q == nil)
    #expect(request.maxResults == 100)
    #expect(request.pageToken == nil)
    #expect(request.labelIds.isEmpty)
    #expect(request.includeSpamTrash == false)
    #expect(request.queryItems == [
      URLQueryItem(name: "maxResults", value: "100"),
      URLQueryItem(name: "includeSpamTrash", value: "false")
    ])
  }

  @Test(arguments: [1, 500])
  func acceptsPageSizeBoundaries(maxResults: Int) throws {
    let request = try GmailThreadListRequest(maxResults: maxResults)

    #expect(request.maxResults == maxResults)
    #expect(request.queryItems.contains(
      URLQueryItem(name: "maxResults", value: String(maxResults))
    ))
  }

  @Test(arguments: [-1, 0, 501, Int.max])
  func rejectsInvalidPageSizes(maxResults: Int) {
    #expect(throws: GmailThreadListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try GmailThreadListRequest(maxResults: maxResults)
    }
  }

  @Test
  func preservesFiltersAndOpaquePageToken() throws {
    let query = #"from:alice+strata@example.com subject:"A&B #1""#
    let token = "page+/=%2F"
    let request = try GmailThreadListRequest(
      q: query,
      maxResults: 250,
      pageToken: token,
      labelIds: ["INBOX", "Label_123"],
      includeSpamTrash: true
    )

    #expect(request.queryItems == [
      URLQueryItem(name: "maxResults", value: "250"),
      URLQueryItem(name: "includeSpamTrash", value: "true"),
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "pageToken", value: token),
      URLQueryItem(name: "labelIds", value: "INBOX"),
      URLQueryItem(name: "labelIds", value: "Label_123")
    ])
  }
}
