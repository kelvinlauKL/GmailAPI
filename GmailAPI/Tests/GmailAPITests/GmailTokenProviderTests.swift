import Foundation
import Testing
import GmailAPI

struct GmailTokenProviderTests {
  @Test
  func retrievesCurrentTokenWithoutCaching() async throws {
    let credentialStore = CredentialStore()
    let provider = GmailTokenProvider(
      retrieveAccessToken: { await credentialStore.currentAccessToken },
      invalidateRejectedAccessToken: { await credentialStore.recordRejection($0) }
    )

    #expect(try await provider.accessToken() == "first-access-token")
    await credentialStore.replaceAccessToken(with: "replacement-access-token")
    #expect(try await provider.accessToken() == "replacement-access-token")
  }

  @Test
  func passesExactRejectedTokenToHost() async throws {
    let credentialStore = CredentialStore()
    let provider = GmailTokenProvider(
      retrieveAccessToken: { await credentialStore.currentAccessToken },
      invalidateRejectedAccessToken: { await credentialStore.recordRejection($0) }
    )
    await credentialStore.replaceAccessToken(with: "replacement-access-token")

    try await provider.invalidate(rejectedAccessToken: "first-access-token")

    #expect(await credentialStore.rejectedAccessTokens == ["first-access-token"])
  }

  @Test(arguments: ["", " ", "Bearer access-token", "access\ntoken", "access\rtoken", "access\ttoken"])
  func rejectsEmptyOrWhitespaceContainingTokens(accessToken: String) async {
    let provider = GmailTokenProvider(
      retrieveAccessToken: { accessToken },
      invalidateRejectedAccessToken: { _ in }
    )

    await #expect(throws: GmailTokenProvider.TokenError.invalidAccessToken) {
      try await provider.accessToken()
    }
  }

  @Test
  func explainsInvalidTokenWithoutDisclosingIt() {
    let error: any LocalizedError = GmailTokenProvider.TokenError.invalidAccessToken

    #expect(error.localizedDescription == "The credential provider returned an invalid access token.")
    #expect(error.failureReason == "The access token was empty or contained whitespace.")
    #expect(error.recoverySuggestion == "Provide a current access token without whitespace or the Bearer prefix.")
  }

  @Test
  func propagatesHostCredentialFailures() async {
    let provider = GmailTokenProvider(
      retrieveAccessToken: { throw CredentialError.unavailable },
      invalidateRejectedAccessToken: { _ in throw CredentialError.unavailable }
    )

    await #expect(throws: CredentialError.unavailable) {
      try await provider.accessToken()
    }
    await #expect(throws: CredentialError.unavailable) {
      try await provider.invalidate(rejectedAccessToken: "rejected-access-token")
    }
  }

  @Test
  func rejectsCancelledWorkBeforeCallingHost() async {
    let provider = GmailTokenProvider(
      retrieveAccessToken: {
        Issue.record("Cancelled work must not request credentials.")
        return "unused-access-token"
      },
      invalidateRejectedAccessToken: { _ in
        Issue.record("Cancelled work must not invalidate credentials.")
      }
    )
    let cancelledTask = Task {
      withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      await #expect(throws: CancellationError.self) {
        try await provider.accessToken()
      }
      await #expect(throws: CancellationError.self) {
        try await provider.invalidate(rejectedAccessToken: "rejected-access-token")
      }
    }

    await cancelledTask.value
  }

  private actor CredentialStore {
    var currentAccessToken = "first-access-token"
    var rejectedAccessTokens: [String] = []

    func replaceAccessToken(with accessToken: String) {
      currentAccessToken = accessToken
    }

    func recordRejection(_ rejectedAccessToken: String) {
      rejectedAccessTokens.append(rejectedAccessToken)
    }
  }

  private enum CredentialError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? { "Test credentials are unavailable." }
    var failureReason: String? { "The test credential handler failed." }
    var recoverySuggestion: String? { "Supply working test credentials and retry." }
  }
}
