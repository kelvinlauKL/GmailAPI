import Foundation
import Testing
@testable import GmailAPI

struct GmailHistoryListRequestTests {
  @Test
  func defaultsToFirstPageWithoutFilters() throws {
    let request = try GmailHistoryListRequest(startHistoryId: "123")

    #expect(request.startHistoryId == "123")
    #expect(request.maxResults == 100)
    #expect(request.pageToken == nil)
    #expect(request.labelId == nil)
    #expect(request.historyTypes.isEmpty)
    #expect(request.queryItems == [
      URLQueryItem(name: "startHistoryId", value: "123"),
      URLQueryItem(name: "maxResults", value: "100")
    ])
  }

  @Test(arguments: [1, 500])
  func acceptsPageSizeBoundaries(maxResults: Int) throws {
    let request = try GmailHistoryListRequest(startHistoryId: "123", maxResults: maxResults)

    #expect(request.maxResults == maxResults)
    #expect(request.queryItems.contains(
      URLQueryItem(name: "maxResults", value: String(maxResults))
    ))
  }

  @Test(arguments: [Int.min, -1, 0, 501, Int.max])
  func rejectsInvalidPageSizes(maxResults: Int) {
    #expect(throws: GmailHistoryListRequest.ValidationError.invalidMaxResults(maxResults)) {
      try GmailHistoryListRequest(startHistoryId: "123", maxResults: maxResults)
    }
  }

  @Test
  func explainsInvalidPageSizeAndHowToRecover() {
    let error: any LocalizedError = GmailHistoryListRequest.ValidationError.invalidMaxResults(501)

    #expect(error.localizedDescription == "Cannot list history with a page size of 501.")
    #expect(error.failureReason == "The page size must be positive and cannot exceed Gmail's limit of 500 history records.")
    #expect(error.recoverySuggestion == "Set maxResults to a value from 1 through 500 and try again.")
  }

  @Test(arguments: ["", " ", "\t", "\r\n", " \t\n", "\u{00A0}"])
  func rejectsMissingStartingHistoryID(startHistoryId: String) {
    #expect(throws: GmailHistoryListRequest.ValidationError.missingStartHistoryID) {
      try GmailHistoryListRequest(startHistoryId: startHistoryId)
    }
  }

  @Test
  func explainsMissingStartingHistoryIDAndHowToRecover() {
    let error: any LocalizedError = GmailHistoryListRequest.ValidationError.missingStartHistoryID

    #expect(error.localizedDescription == "Cannot list history without a starting history ID.")
    #expect(error.failureReason == "The starting history ID is empty or contains only whitespace.")
    #expect(error.recoverySuggestion == "Pass a historyId from a previous Gmail response as startHistoryId.")
  }

  @Test(arguments: ["18446744073709551615", "000123", "opaque+/=%2F", " 123 "])
  func preservesOpaqueStartingHistoryID(startHistoryId: String) throws {
    let request = try GmailHistoryListRequest(startHistoryId: startHistoryId)

    #expect(request.startHistoryId == startHistoryId)
    #expect(request.queryItems.contains(
      URLQueryItem(name: "startHistoryId", value: startHistoryId)
    ))
  }

  @Test
  func preservesFiltersAndOpaquePageToken() throws {
    let pageToken = "page+/=%2F &next=#fragment"
    let labelId = "Label_+/%2F &?#"
    let request = try GmailHistoryListRequest(
      startHistoryId: "123",
      maxResults: 250,
      pageToken: pageToken,
      labelId: labelId,
      historyTypes: [.labelRemoved, .messageAdded, .messageDeleted, .labelAdded]
    )

    #expect(request.startHistoryId == "123")
    #expect(request.maxResults == 250)
    #expect(request.pageToken == pageToken)
    #expect(request.labelId == labelId)
    #expect(request.historyTypes == [.labelRemoved, .messageAdded, .messageDeleted, .labelAdded])
    #expect(request.queryItems == [
      URLQueryItem(name: "startHistoryId", value: "123"),
      URLQueryItem(name: "maxResults", value: "250"),
      URLQueryItem(name: "pageToken", value: pageToken),
      URLQueryItem(name: "labelId", value: labelId),
      URLQueryItem(name: "historyTypes", value: "labelRemoved"),
      URLQueryItem(name: "historyTypes", value: "messageAdded"),
      URLQueryItem(name: "historyTypes", value: "messageDeleted"),
      URLQueryItem(name: "historyTypes", value: "labelAdded")
    ])
  }
}
