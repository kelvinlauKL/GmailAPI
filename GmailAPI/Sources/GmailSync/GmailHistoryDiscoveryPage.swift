import Foundation
import GmailAPI

/// Conversation fetch work and pagination metadata derived from one unfiltered history page.
/// This value does not persist work, fetch messages, or decide conversation membership.
public struct GmailHistoryDiscoveryPage: Equatable, Sendable {
  public let accountID: String

  /// The request that produced this response. Retained so checkpoints can reject mismatched pages.
  public let request: GmailHistoryListRequest

  /// Every affected conversation, deduplicated within this page and sorted by its opaque thread ID.
  /// All change kinds, including deletions and label removals, schedule a fresh conversation fetch.
  public let conversationIDs: [GmailConversationID]

  /// The response's mailbox cursor. It may advance the committed cursor only on the final page.
  public let historyId: String

  /// `nil` marks the final page. An empty response token is normalized to `nil`.
  public let nextPageToken: String?

  /// The caller must pair the actual request and response from the same connected account.
  /// Filters are rejected because they can omit changes that remove conversations from selection.
  /// Malformed conversation IDs fail the entire conversion instead of silently dropping work.
  public init(accountID: String, request: GmailHistoryListRequest, response: GmailHistoryListResponse) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GmailConversationID.ValidationError.emptyAccountID
    }
    guard request.labelId == nil, request.historyTypes.isEmpty else {
      throw ValidationError.filteredRequest
    }
    guard !response.historyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.missingHistoryID
    }

    var conversationIDs: Set<GmailConversationID> = []
    for historyRecord in response.history ?? [] {
      // The general list may duplicate specific events or contain additional changed messages.
      // Union all lists because fetching needs affected conversations, not individual event kinds.
      let messageGroups: [[GmailMessage]] = [
        historyRecord.messages ?? [],
        historyRecord.messagesAdded?.map(\.message) ?? [],
        historyRecord.messagesDeleted?.map(\.message) ?? [],
        historyRecord.labelsAdded?.map(\.message) ?? [],
        historyRecord.labelsRemoved?.map(\.message) ?? []
      ]
      for messages in messageGroups {
        for message in messages {
          conversationIDs.insert(try GmailConversationID(accountID: accountID, threadID: message.threadId))
        }
      }
    }

    self.accountID = accountID
    self.request = request
    self.conversationIDs = conversationIDs.sorted { firstConversation, secondConversation in
      firstConversation.threadID < secondConversation.threadID
    }
    self.historyId = response.historyId
    self.nextPageToken = response.nextPageToken.flatMap { pageToken in pageToken.isEmpty ? nil : pageToken }
  }
}

public extension GmailHistoryDiscoveryPage {
  enum ValidationError: LocalizedError, Equatable {
    case filteredRequest
    case missingHistoryID

    public var errorDescription: String? {
      "Cannot prepare the Gmail history page for synchronization."
    }

    public var failureReason: String? {
      switch self {
      case .filteredRequest: "The history request restricts labels or change types."
      case .missingHistoryID: "The response has no usable mailbox history ID."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .filteredRequest:
        "Request history without labelId or historyTypes filters, then evaluate selection on fetched conversations."
      case .missingHistoryID:
        "Keep the current checkpoint and retry the history request before saving this page."
      }
    }
  }
}
