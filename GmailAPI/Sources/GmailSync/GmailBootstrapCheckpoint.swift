import Foundation
import GmailAPI

/// A resumable initial import or recovery scan, followed by history replay from its saved baseline.
/// This value describes progress; the host must persist page work and checkpoint changes atomically.
public struct GmailBootstrapCheckpoint: Codable, Equatable, Sendable {
  public let accountID: String

  /// Allocate a fresh generation for a new import, a policy change, or an expired-baseline recovery.
  public let importGeneration: UUID

  /// Fixed selection rules for this generation. Evaluate them on fetched conversations.
  public let policy: GmailSyncPolicy

  /// Capture and save this mailbox history ID before issuing the first thread-list request.
  /// Replaying from this baseline discovers changes that arrived during enumeration.
  public let baselineHistoryId: String

  /// The thread-list page size, preserved across resumptions.
  public let maxResults: Int

  public let position: Position

  public init(
    accountID: String,
    importGeneration: UUID,
    policy: GmailSyncPolicy,
    baselineHistoryId: String,
    maxResults: Int = GmailThreadListRequest.Constant.defaultPageSize,
    position: Position = .listing(pageToken: nil)
  ) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GmailConversationID.ValidationError.emptyAccountID
    }
    _ = try GmailHistoryListRequest(startHistoryId: baselineHistoryId)
    _ = try GmailThreadListRequest(maxResults: maxResults)
    self.accountID = accountID
    self.importGeneration = importGeneration
    self.policy = policy
    self.baselineHistoryId = baselineHistoryId
    self.maxResults = maxResults
    self.position = position
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      accountID: container.decode(String.self, forKey: .accountID),
      importGeneration: container.decode(UUID.self, forKey: .importGeneration),
      policy: container.decode(GmailSyncPolicy.self, forKey: .policy),
      baselineHistoryId: container.decode(String.self, forKey: .baselineHistoryId),
      maxResults: container.decode(Int.self, forKey: .maxResults),
      position: container.decode(Position.self, forKey: .position)
    )
  }

  /// Returns nil once enumeration finishes, so a final page cannot accidentally restart listing.
  /// Date, label, and draft selection happens on fetched threads rather than in a Gmail query.
  public func makeRequest() throws -> GmailThreadListRequest? {
    guard case .listing(let pageToken) = position else { return nil }
    return try GmailThreadListRequest(
      maxResults: maxResults, pageToken: pageToken, includeSpamTrash: policy.includeSpamTrash
    )
  }

  /// Computes the successor to save with every conversation ID from this page.
  /// The store must also verify its current checkpoint and account lease/fence in that transaction.
  public func advancing(after page: GmailThreadDiscoveryPage) throws -> Self {
    guard let request = try makeRequest() else { throw TransitionError.listingAlreadyComplete }
    guard page.accountID == accountID else { throw TransitionError.accountMismatch }
    guard page.importGeneration == importGeneration else { throw TransitionError.importGenerationMismatch }
    guard page.request == request else { throw TransitionError.requestMismatch }
    if let nextPageToken = page.nextPageToken, nextPageToken == request.pageToken {
      throw TransitionError.repeatedPageToken
    }
    let nextPosition: Position = page.nextPageToken.map { pageToken in
      .listing(pageToken: pageToken)
    } ?? .awaitingHistoryReplay
    return try Self(
      accountID: accountID, importGeneration: importGeneration, policy: policy,
      baselineHistoryId: baselineHistoryId, maxResults: maxResults, position: nextPosition
    )
  }

  /// Prepares history replay only after enumeration finishes, always using the original baseline.
  /// Persist final listing work before starting replay. Retain the import generation and policy
  /// in account state until replay and reconciliation finish; this value does not complete them.
  public func makeHistoryCheckpoint(
    maxResults: Int = GmailHistoryListRequest.Constant.defaultPageSize
  ) throws -> GmailHistoryCheckpoint {
    guard position == .awaitingHistoryReplay else { throw TransitionError.listingNotComplete }
    return try GmailHistoryCheckpoint(accountID: accountID, historyId: baselineHistoryId, maxResults: maxResults)
  }
}

public extension GmailBootstrapCheckpoint {
  enum Position: Codable, Equatable, Sendable {
    /// A nil token means the first page, not completed enumeration.
    case listing(pageToken: String?)
    case awaitingHistoryReplay
  }

  enum TransitionError: LocalizedError, Equatable {
    case listingAlreadyComplete
    case listingNotComplete
    case accountMismatch
    case importGenerationMismatch
    case requestMismatch
    case repeatedPageToken

    public var errorDescription: String? {
      "Cannot advance the Gmail import checkpoint."
    }

    public var failureReason: String? {
      switch self {
      case .listingAlreadyComplete: "Thread enumeration has already finished."
      case .listingNotComplete: "Thread enumeration has not finished yet."
      case .accountMismatch: "The thread page belongs to a different account."
      case .importGenerationMismatch: "The thread page belongs to a different import generation."
      case .requestMismatch: "The page's request does not match the checkpoint's listing settings."
      case .repeatedPageToken: "The response repeats the page token that was just requested."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .listingAlreadyComplete:
        "Save the final listing work and continue with history replay from the saved baseline."
      case .listingNotComplete:
        "Continue listing and saving each page's work before beginning history replay."
      case .accountMismatch, .importGenerationMismatch, .requestMismatch:
        "Reload the active import checkpoint and use its account, generation, and next request."
      case .repeatedPageToken:
        "Keep the saved baseline and restart enumeration, deduplicating already recorded work."
      }
    }
  }
}
