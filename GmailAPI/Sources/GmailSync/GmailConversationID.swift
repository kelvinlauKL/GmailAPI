import Foundation

/// Identifies a conversation within one host-managed account.
/// Persist both fields together; Gmail thread IDs are not application-wide identifiers.
public struct GmailConversationID: Codable, Hashable, Sendable {
  /// A stable identifier supplied by the host, independent of the account's email address.
  public let accountID: String

  /// Gmail's opaque thread ID, preserved without parsing or normalization.
  public let threadID: String

  public init(accountID: String, threadID: String) throws {
    guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyAccountID
    }
    guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyThreadID
    }
    self.accountID = accountID
    self.threadID = threadID
  }

  /// Restores a key while enforcing the same validation as direct initialization.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      accountID: container.decode(String.self, forKey: .accountID),
      threadID: container.decode(String.self, forKey: .threadID)
    )
  }
}

public extension GmailConversationID {
  enum ValidationError: LocalizedError, Equatable {
    case emptyAccountID
    case emptyThreadID

    public var errorDescription: String? {
      "Cannot identify the Gmail conversation."
    }

    public var failureReason: String? {
      switch self {
      case .emptyAccountID: "The account ID is empty or contains only whitespace."
      case .emptyThreadID: "The thread ID is empty or contains only whitespace."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .emptyAccountID: "Supply the host's stable identifier for the connected account."
      case .emptyThreadID: "Supply the thread ID returned by Gmail."
      }
    }
  }
}
