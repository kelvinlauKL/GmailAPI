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

  @Test(arguments: [
    (400, GmailRequestFailure.Category.badRequest, false),
    (401, .unauthorized, false),
    (403, .forbidden, false),
    (404, .notFound, false),
    (429, .rateLimited, true),
    (500, .serverError, true),
    (501, .serverError, false),
    (502, .serverError, true),
    (503, .serverError, true),
    (504, .serverError, true),
    (599, .serverError, false),
    (600, .other, false),
    (418, .other, false),
    (200, .other, false)
  ])
  func classifiesHTTPStatusAndRetryability(
    statusCode: Int, expectedCategory: GmailRequestFailure.Category, expectedRetryability: Bool
  ) {
    let failure = GmailRequestFailure(statusCode: statusCode)

    #expect(failure.category == expectedCategory)
    #expect(failure.isRetryable == expectedRetryability)
  }

  @Test(arguments: [
    ["rateLimitExceeded"], ["userRateLimitExceeded"],
    ["rateLimitExceeded", "userRateLimitExceeded"]
  ])
  func recognizesTemporaryForbiddenReasons(reasons: [String]) throws {
    let failure = try makeFailure(reasons: reasons)

    #expect(failure.category == .rateLimited)
    #expect(failure.isRetryable)
  }

  @Test(arguments: [
    [], ["domainPolicy"], ["insufficientPermissions"], ["futureReason"], [""],
    ["rateLimitExceeded", "domainPolicy"], ["domainPolicy", "rateLimitExceeded"],
    ["userRateLimitExceeded", "futureReason"], ["dailyLimitExceeded", "futureReason"]
  ])
  func doesNotRetryUnrecognizedOrMixedForbiddenReasons(reasons: [String]) throws {
    let failure = try makeFailure(reasons: reasons)

    #expect(failure.category == .forbidden)
    #expect(!failure.isRetryable)
  }

  @Test(arguments: [
    ["dailyLimitExceeded"],
    ["rateLimitExceeded", "dailyLimitExceeded"],
    ["dailyLimitExceeded", "userRateLimitExceeded"]
  ])
  func distinguishesDailyQuotaFromTemporaryRateLimits(reasons: [String]) throws {
    let failure = try makeFailure(reasons: reasons)

    #expect(failure.category == .quotaExceeded)
    #expect(!failure.isRetryable)
  }

  @Test
  func usesHTTPStatusInsteadOfBodyCodeOrUnrelatedReasons() throws {
    let missingResource = try makeFailure(statusCode: 404, reasons: ["rateLimitExceeded"])
    let invalidRequest = try makeFailure(statusCode: 400, reasons: ["userRateLimitExceeded"])
    let serverFailure = try makeFailure(statusCode: 503, reasons: ["domainPolicy"])

    #expect(missingResource.details?.code == 403)
    #expect(missingResource.category == .notFound)
    #expect(!missingResource.isRetryable)
    #expect(invalidRequest.category == .badRequest)
    #expect(!invalidRequest.isRetryable)
    #expect(serverFailure.category == .serverError)
    #expect(serverFailure.isRetryable)
  }

  @Test
  func interpretsNotFoundAsExpiredHistoryOnlyForHistoryListing() {
    let missingResource = GmailRequestFailure(statusCode: 404)
    let expiredHistory = GmailRequestFailure(statusCode: 404, context: .historyList)
    let forbiddenHistory = GmailRequestFailure(statusCode: 403, context: .historyList)

    #expect(missingResource.context == .general)
    #expect(missingResource.category == .notFound)
    #expect(expiredHistory.context == .historyList)
    #expect(expiredHistory.category == .historyExpired)
    #expect(!expiredHistory.isRetryable)
    #expect(forbiddenHistory.category == .forbidden)
  }

  @Test
  func explainsDifferentRecoveryActions() throws {
    let expiredHistory = GmailRequestFailure(statusCode: 404, context: .historyList)
    let rateLimit = try makeFailure(reasons: ["userRateLimitExceeded"])
    let dailyQuota = try makeFailure(reasons: ["dailyLimitExceeded"])

    #expect(expiredHistory.failureReason == "The starting history ID is invalid or expired.")
    #expect(expiredHistory.recoverySuggestion == "Perform a full mailbox sync before requesting incremental changes again.")
    #expect(rateLimit.recoverySuggestion == "Reduce request volume and retry with backoff, honoring Retry-After when supplied.")
    #expect(dailyQuota.recoverySuggestion == "Check the project's daily quota and wait for it to reset or adjust it before retrying.")
  }

  private func makeFailure(statusCode: Int = 403, reasons: [String]) throws -> GmailRequestFailure {
    let responseData = try JSONSerialization.data(withJSONObject: [
      "error": ["code": 403, "errors": reasons.map { ["reason": $0] }]
    ])
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: responseData)
    return GmailRequestFailure(statusCode: statusCode, details: response.error)
  }
}
