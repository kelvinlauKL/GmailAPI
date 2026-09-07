import Foundation
import Testing
@testable import GmailAPI

struct ExponentialGmailRetryPolicyTests {
  @Test
  func providesBoundedDefaults() {
    let policy = ExponentialGmailRetryPolicy()

    #expect(policy.maximumRetries == 3)
    #expect(policy.initialDelay == 1)
    #expect(policy.maximumDelay == 60)
  }

  @Test
  func acceptsCustomLimitsAndDisabledRetries() throws {
    let policy = try ExponentialGmailRetryPolicy(maximumRetries: 5, initialDelay: 2, maximumDelay: 10)
    let disabledPolicy = try ExponentialGmailRetryPolicy(maximumRetries: 0)

    #expect(policy.maximumRetries == 5)
    #expect(policy.initialDelay == 2)
    #expect(policy.maximumDelay == 10)
    #expect(delay(using: disabledPolicy) == nil)
  }

  @Test(arguments: [-1, Int.min])
  func rejectsNegativeRetryCounts(maximumRetries: Int) {
    #expect(throws: ExponentialGmailRetryPolicy.ValidationError.invalidMaximumRetries(maximumRetries)) {
      try ExponentialGmailRetryPolicy(maximumRetries: maximumRetries)
    }
  }

  @Test(arguments: [-1.0, 0, 0.5, .nan, .infinity, -.infinity])
  func rejectsInvalidInitialDelays(initialDelay: TimeInterval) {
    #expect(throws: ExponentialGmailRetryPolicy.ValidationError.self) {
      try ExponentialGmailRetryPolicy(maximumRetries: 1, initialDelay: initialDelay)
    }
  }

  @Test(arguments: [-1.0, 0, 0.5, .nan, .infinity, -.infinity, TimeInterval(Int64.max)])
  func rejectsInvalidMaximumDelays(maximumDelay: TimeInterval) {
    #expect(throws: ExponentialGmailRetryPolicy.ValidationError.self) {
      try ExponentialGmailRetryPolicy(maximumRetries: 1, maximumDelay: maximumDelay)
    }
  }

  @Test
  func rejectsAMaximumDelayShorterThanTheInitialDelay() {
    #expect(throws: ExponentialGmailRetryPolicy.ValidationError.invalidMaximumDelay(2)) {
      try ExponentialGmailRetryPolicy(maximumRetries: 1, initialDelay: 3, maximumDelay: 2)
    }
  }

  @Test(arguments: [
    ExponentialGmailRetryPolicy.ValidationError.invalidMaximumRetries(-1),
    .invalidInitialDelay(0), .invalidMaximumDelay(0)
  ])
  func explainsHowToCorrectInvalidLimits(error: ExponentialGmailRetryPolicy.ValidationError) throws {
    #expect(!(try #require(error.errorDescription)).isEmpty)
    #expect(!(try #require(error.failureReason)).isEmpty)
    #expect(!(try #require(error.recoverySuggestion)).isEmpty)
  }

  @Test(arguments: [(0, 1.0), (1, 2.0), (2, 4.0)])
  func doublesTheBackoff(retryCount: Int, expectedDelay: TimeInterval) {
    #expect(delay(retryCount: retryCount) == expectedDelay)
  }

  @Test(arguments: [-1, 3, Int.max])
  func stopsOutsideTheRetryBudget(retryCount: Int) {
    #expect(delay(retryCount: retryCount) == nil)
  }

  @Test
  func addsJitterAndCapsTheWholeWait() throws {
    let policy = try ExponentialGmailRetryPolicy(maximumRetries: Int.max, initialDelay: 2, maximumDelay: 10)

    #expect(delay(using: policy, jitterFraction: 0.5) == 3)
    #expect(delay(using: policy, retryCount: 1, jitterFraction: 1) == 8)
    #expect(delay(using: policy, retryCount: 2, jitterFraction: 1) == 10)
    #expect(delay(using: policy, retryCount: Int.max - 1, jitterFraction: 1) == 10)
  }

  @Test(arguments: [-0.1, 1.1, .nan, .infinity])
  func rejectsInvalidJitterFractions(jitterFraction: Double) {
    #expect(delay(jitterFraction: jitterFraction) == nil)
  }

  @Test(arguments: [400, 401, 403, 404, 501, 599])
  func doesNotRetryPermanentHTTPFailures(statusCode: Int) {
    let failure = GmailRequestFailure(statusCode: statusCode, retryAfter: "1")

    #expect(delay(after: failure) == nil)
  }

  @Test(arguments: [429, 500, 502, 503, 504])
  func retriesTemporaryHTTPFailures(statusCode: Int) {
    #expect(delay(after: GmailRequestFailure(statusCode: statusCode)) == 1)
  }

  @Test
  func usesGmailsForbiddenReasonClassification() throws {
    let data = Data(#"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: data)

    #expect(delay(after: GmailRequestFailure(statusCode: 403, details: response.error)) == 1)
  }

  @Test(arguments: [
    URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost,
    .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet
  ])
  func retriesTemporaryConnectionFailures(code: URLError.Code) {
    #expect(delay(after: URLError(code)) == 1)
  }

  @Test(arguments: [
    URLError.Code.cancelled, .badURL, .unsupportedURL, .secureConnectionFailed,
    .serverCertificateUntrusted, .userAuthenticationRequired, .unknown
  ])
  func doesNotRetryOtherConnectionFailures(code: URLError.Code) {
    #expect(delay(after: URLError(code)) == nil)
  }

  @Test
  func doesNotRetryUnknownErrorsOrCancellation() {
    #expect(delay(after: UnexpectedFailure()) == nil)
    #expect(delay(after: CancellationError()) == nil)
  }

  @Test(arguments: [("0", 2.0), ("1", 2.0), ("10", 10.0), ("60", 60.0), ("invalid", 2.0)])
  func honorsTheLongerOfBackoffAndRetryAfter(header: String, expectedDelay: TimeInterval) {
    let failure = GmailRequestFailure(statusCode: 503, retryAfter: header)

    #expect(delay(after: failure, jitterFraction: 1) == expectedDelay)
  }

  @Test
  func resolvesRetryAfterDatesAgainstTheCurrentTime() {
    let failure = GmailRequestFailure(statusCode: 503, retryAfter: "Sun, 06 Nov 1994 08:49:37 GMT")
    let policy = ExponentialGmailRetryPolicy()

    #expect(policy.retryDelay(
      after: failure, retryCount: 0, now: Date(timeIntervalSince1970: 784_111_717), jitterFraction: 0
    ) == 60)
    #expect(policy.retryDelay(
      after: failure, retryCount: 0, now: Date(timeIntervalSince1970: 784_111_800), jitterFraction: 0
    ) == 1)
  }

  @Test(arguments: ["61", "9007199254740993", String(repeating: "9", count: 400)])
  func stopsRatherThanShorteningAnExcessiveServerWait(header: String) {
    #expect(delay(after: GmailRequestFailure(statusCode: 503, retryAfter: header)) == nil)
  }

  @Test
  func returnsTrueOnlyAfterWaiting() async throws {
    let policy = try ExponentialGmailRetryPolicy(maximumRetries: 1, maximumDelay: 1)
    let clock = ContinuousClock()
    let start = clock.now

    let shouldRetry = try await policy.waitBeforeRetry(after: GmailRequestFailure(statusCode: 503), retryCount: 0)

    #expect(shouldRetry)
    #expect(start.duration(to: clock.now) >= .seconds(1))
  }

  @Test
  func declinesAnExhaustedRetryWithoutWaiting() async throws {
    let shouldRetry = try await ExponentialGmailRetryPolicy().waitBeforeRetry(
      after: GmailRequestFailure(statusCode: 503), retryCount: 3
    )

    #expect(!shouldRetry)
  }

  @Test
  func propagatesCancellation() async {
    let task = Task {
      try await ExponentialGmailRetryPolicy().waitBeforeRetry(after: GmailRequestFailure(statusCode: 503), retryCount: 0)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private func delay(
    using policy: ExponentialGmailRetryPolicy = ExponentialGmailRetryPolicy(),
    after error: any Error = GmailRequestFailure(statusCode: 503),
    retryCount: Int = 0,
    jitterFraction: Double = 0
  ) -> TimeInterval? {
    policy.retryDelay(after: error, retryCount: retryCount, now: Date(timeIntervalSince1970: 0), jitterFraction: jitterFraction)
  }
}

private extension ExponentialGmailRetryPolicyTests {
  struct UnexpectedFailure: Error {}
}
