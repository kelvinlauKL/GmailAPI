import Foundation
import GmailAPI

/// Applies the package's date, label, spam/trash, and draft selection rules.
public struct GmailPolicyThreadSelector: GmailThreadSelector {
  public init() {}

  /// Evaluate a full fetched thread, not the partial messages returned by history discovery.
  /// A qualifying thread retains all permitted context in source order, including older messages
  /// and messages without the required labels. Omitted label arrays are treated as empty.
  /// A missing or invalid date throws only when it prevents deciding whether the thread qualifies.
  /// This does not normalize messages or establish that their content is complete.
  public func messages(in thread: GmailThread, matching policy: GmailSyncPolicy) throws -> [GmailMessage] {
    let permittedMessages = thread.messages.filter { message in
      let labelIDs = Set(message.labelIds ?? [])
      return (policy.includeDrafts || !labelIDs.contains(Constant.draftLabelID))
        && (policy.includeSpamTrash || labelIDs.isDisjoint(with: Constant.spamTrashLabelIDs))
    }
    let requiredLabelIDs = Set(policy.requiredLabelIds)
    var hasQualifyingMessage = false
    var hasUnknownMessageDate = false

    for message in permittedMessages {
      guard requiredLabelIDs.isSubset(of: Set(message.labelIds ?? [])) else { continue }
      guard let oldestMessageDate = policy.oldestMessageDate else {
        hasQualifyingMessage = true
        continue
      }
      guard let internalDate = message.internalDate, let milliseconds = Int64(internalDate) else {
        hasUnknownMessageDate = true
        continue
      }
      let messageDate = Date(timeIntervalSince1970: Double(milliseconds) / Constant.millisecondsPerSecond)
      if messageDate >= oldestMessageDate {
        hasQualifyingMessage = true
      }
    }

    if hasQualifyingMessage { return permittedMessages }
    if hasUnknownMessageDate { throw SelectionError.invalidInternalDate }
    return []
  }
}

public extension GmailPolicyThreadSelector {
  enum SelectionError: LocalizedError, Equatable {
    case invalidInternalDate

    public var errorDescription: String? {
      "Cannot determine whether the Gmail conversation matches the selection policy."
    }

    public var failureReason: String? {
      "A message that could qualify has a missing or invalid internal date."
    }

    public var recoverySuggestion: String? {
      "Fetch the full conversation again and keep its previous membership until selection succeeds."
    }
  }
}

private extension GmailPolicyThreadSelector {
  enum Constant {
    static let draftLabelID: String = "DRAFT"
    static let spamTrashLabelIDs: Set<String> = ["SPAM", "TRASH"]
    static let millisecondsPerSecond: Double = 1_000
  }
}
