import Foundation
import GmailAPI

/// Conversation fetch work derived from one page of an initial import or recovery scan.
/// This value prepares work in memory; it does not fetch conversations or save a checkpoint.
public struct GmailThreadDiscoveryPage: Equatable, Sendable {
  public let accountID: String

  /// The import generation that initiated the request, retained to reject stale scan responses.
  public let importGeneration: UUID

  /// The actual request that produced this page, including its pagination and spam/trash settings.
  public let request: GmailThreadListRequest

  /// Unique account-scoped conversation IDs, sorted by their opaque thread IDs.
  public let conversationIDs: [GmailConversationID]

  /// `nil` marks the final page. An empty response token is normalized to `nil`.
  /// The response's resultSizeEstimate never determines whether listing is complete.
  public let nextPageToken: String?

  /// Associate the response with the account, generation, and request used to fetch it.
  /// Search and label filters are rejected; evaluate date, label, and draft policy on full threads.
  /// The request may include or exclude spam/trash according to the import's fixed policy.
  public init(
    accountID: String,
    importGeneration: UUID,
    request: GmailThreadListRequest,
    response: GmailThreadListResponse
  ) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GmailConversationID.ValidationError.emptyAccountID
    }
    guard request.q.isEmpty, request.labelIds.isEmpty else { throw ValidationError.filteredRequest }

    var conversationIDs: Set<GmailConversationID> = []
    for thread in response.threads ?? [] {
      conversationIDs.insert(try GmailConversationID(accountID: accountID, threadID: thread.id))
    }

    self.accountID = accountID
    self.importGeneration = importGeneration
    self.request = request
    self.conversationIDs = conversationIDs.sorted { firstConversation, secondConversation in
      firstConversation.threadID < secondConversation.threadID
    }
    self.nextPageToken = response.nextPageToken.flatMap { pageToken in pageToken.isEmpty ? nil : pageToken }
  }
}

public extension GmailThreadDiscoveryPage {
  enum ValidationError: LocalizedError, Equatable {
    case filteredRequest

    public var errorDescription: String? {
      "Cannot prepare the Gmail thread page for synchronization."
    }

    public var failureReason: String? {
      "The thread-list request restricts results with a search query or label IDs."
    }

    public var recoverySuggestion: String? {
      "List threads without q or labelIds filters, then apply the selection policy to fetched conversations."
    }
  }
}
