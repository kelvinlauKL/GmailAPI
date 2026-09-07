import Foundation
import GmailAPI

/// Loads an import baseline and individual thread-list pages without owning persistence or scheduling.
/// The host must associate accountID with this client's authenticated account; the host's stable ID
/// cannot be inferred from a Gmail email address. Request retries follow the client's retry policy.
public struct GmailBootstrapDiscovery: Sendable {
  private let client: GmailClient
  private let accountID: String

  public init(client: GmailClient, accountID: String) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GmailConversationID.ValidationError.emptyAccountID
    }
    self.client = client
    self.accountID = accountID
  }

  /// Fetches the mailbox baseline without listing any threads.
  /// Under the account lease, save this new generation and checkpoint before requesting its first page.
  /// Resume an existing import from its saved checkpoint rather than capturing a replacement baseline.
  public func start(
    importGeneration: UUID,
    policy: GmailSyncPolicy,
    maxResults: Int = GmailThreadListRequest.Constant.defaultPageSize
  ) async throws -> GmailBootstrapCheckpoint {
    _ = try GmailThreadListRequest(maxResults: maxResults)
    let profile = try await client.profile()
    return try GmailBootstrapCheckpoint(
      accountID: accountID, importGeneration: importGeneration, policy: policy,
      baselineHistoryId: profile.historyId, maxResults: maxResults
    )
  }

  /// Loads one logical listing page, or returns nil once enumeration has finished.
  /// The returned successor is only a proposal. Before using it, the store must verify the expected
  /// checkpoint and account lease/fence, then atomically save all discovered work and the successor.
  /// Errors leave the supplied checkpoint unchanged; this method does not restart scans or prefetch.
  public func nextPage(after checkpoint: GmailBootstrapCheckpoint) async throws -> Page? {
    guard checkpoint.accountID == accountID else { throw GmailBootstrapCheckpoint.TransitionError.accountMismatch }
    guard let request = try checkpoint.makeRequest() else { return nil }
    let response = try await client.listThreads(request)
    let discoveryPage = try GmailThreadDiscoveryPage(
      accountID: accountID, importGeneration: checkpoint.importGeneration, request: request, response: response
    )
    return Page(
      expectedCheckpoint: checkpoint,
      discoveryPage: discoveryPage,
      nextCheckpoint: try checkpoint.advancing(after: discoveryPage)
    )
  }
}

public extension GmailBootstrapDiscovery {
  /// A request-bound bundle for one atomic discovery-page transaction in the host's store.
  struct Page: Equatable, Sendable {
    /// The stored checkpoint that must still match before committing this page.
    public let expectedCheckpoint: GmailBootstrapCheckpoint

    /// Conversation fetch work, scoped to the expected account and import generation.
    public let discoveryPage: GmailThreadDiscoveryPage

    /// Save with the page's work only after checking the current checkpoint and lease/fence.
    public let nextCheckpoint: GmailBootstrapCheckpoint
  }
}
