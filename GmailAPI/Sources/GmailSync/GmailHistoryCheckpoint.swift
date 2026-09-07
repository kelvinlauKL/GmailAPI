import Foundation
import GmailAPI

/// A persistable position in unfiltered history discovery for one account.
/// Computing a successor performs no storage writes and does not make discovered work durable.
public struct GmailHistoryCheckpoint: Codable, Equatable, Sendable {
  public let accountID: String

  /// The committed mailbox cursor, also used as startHistoryId throughout a paginated traversal.
  /// Intermediate response cursors do not replace it.
  public let historyId: String

  /// The page size is retained so resumed requests preserve the original request settings.
  public let maxResults: Int

  /// The next page to request, or nil to begin history discovery from historyId.
  public let pageToken: String?

  public init(
    accountID: String,
    historyId: String,
    maxResults: Int = GmailHistoryListRequest.Constant.defaultPageSize,
    pageToken: String? = nil
  ) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GmailConversationID.ValidationError.emptyAccountID
    }
    let request = try GmailHistoryListRequest(startHistoryId: historyId, maxResults: maxResults, pageToken: pageToken)
    self.accountID = accountID
    self.historyId = request.startHistoryId
    self.maxResults = request.maxResults
    self.pageToken = request.pageToken
  }

  /// Restores a checkpoint using the same validation as direct initialization.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      accountID: container.decode(String.self, forKey: .accountID),
      historyId: container.decode(String.self, forKey: .historyId),
      maxResults: container.decode(Int.self, forKey: .maxResults),
      pageToken: container.decodeIfPresent(String.self, forKey: .pageToken)
    )
  }

  /// Reconstructs the next request without label or change-type filters.
  public func makeRequest() throws -> GmailHistoryListRequest {
    try GmailHistoryListRequest(startHistoryId: historyId, maxResults: maxResults, pageToken: pageToken)
  }

  /// Computes the checkpoint to save alongside all of this page's conversation fetch work.
  /// The store must verify its current checkpoint and account lease/fence, then atomically save
  /// both the work and this successor. These value checks alone do not prevent stale worker writes.
  /// Only a final page replaces historyId; a continuation that repeats the current token is rejected.
  public func advancing(after page: GmailHistoryDiscoveryPage) throws -> Self {
    guard page.accountID == accountID else { throw AdvancementError.accountMismatch }
    guard page.request == (try makeRequest()) else { throw AdvancementError.requestMismatch }
    if let nextPageToken = page.nextPageToken, nextPageToken == pageToken {
      throw AdvancementError.repeatedPageToken
    }

    return try Self(
      accountID: accountID,
      historyId: page.nextPageToken == nil ? page.historyId : historyId,
      maxResults: maxResults,
      pageToken: page.nextPageToken
    )
  }
}

public extension GmailHistoryCheckpoint {
  enum AdvancementError: LocalizedError, Equatable {
    case accountMismatch
    case requestMismatch
    case repeatedPageToken

    public var errorDescription: String? {
      "Cannot advance the Gmail history checkpoint."
    }

    public var failureReason: String? {
      switch self {
      case .accountMismatch:
        "The history page belongs to a different account."
      case .requestMismatch:
        "The page's starting cursor, page token, or page size does not match this checkpoint."
      case .repeatedPageToken:
        "The response repeats the page token that was just requested."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .accountMismatch:
        "Use the checkpoint and connected Gmail client for the page's account."
      case .requestMismatch:
        "Reload the current checkpoint and fetch its next request before advancing."
      case .repeatedPageToken:
        "Keep the committed history ID and restart pagination, deduplicating previously saved work."
      }
    }
  }
}
