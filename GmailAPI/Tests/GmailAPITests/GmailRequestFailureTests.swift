import Foundation
import Testing
import GmailAPI

struct GmailRequestFailureTests {
  @Test
  func representsFailuresWithoutDiagnostics() {
    let failure = GmailRequestFailure(statusCode: 503)

    #expect(failure.statusCode == 503)
    #expect(failure.details == nil)
    #expect(failure.retryAfter == nil)
  }

  @Test
  func preservesHTTPStatusSeparatelyFromReportedCode() throws {
    let json = #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    let failure = GmailRequestFailure(statusCode: 429, details: response.error)

    #expect(failure.statusCode == 429)
    #expect(failure.details?.code == 403)
    #expect(failure.details?.errors?.map(\.reason) == ["userRateLimitExceeded"])
    #expect(failure.localizedDescription == "The Gmail request failed with HTTP status 429.")
  }

  @Test(arguments: ["120", "Wed, 21 Oct 2015 07:28:00 GMT", "unknown-value", ""])
  func preservesRetryAfterWithoutInterpretingIt(retryAfter: String) {
    let failure = GmailRequestFailure(statusCode: 503, retryAfter: retryAfter)

    #expect(failure.retryAfter == retryAfter)
  }

  @Test
  func keepsServerDiagnosticsOutOfLocalizedMessages() throws {
    let privateContent = "private-response-content"
    let json = """
      {"error":{"code":403,"message":"\(privateContent)","errors":[{
        "reason":"\(privateContent)","domain":"\(privateContent)",
        "message":"\(privateContent)","location":"\(privateContent)","locationType":"\(privateContent)"
      }]}}
      """
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    let failure = GmailRequestFailure(statusCode: 403, details: response.error, retryAfter: privateContent)
    let failureReason = try #require(failure.failureReason)
    let recoverySuggestion = try #require(failure.recoverySuggestion)

    #expect(failure.details?.message == privateContent)
    #expect(failure.details?.errors?.first?.message == privateContent)
    #expect(!failure.localizedDescription.contains(privateContent))
    #expect(!failureReason.isEmpty && !failureReason.contains(privateContent))
    #expect(!recoverySuggestion.isEmpty && !recoverySuggestion.contains(privateContent))
  }
}
