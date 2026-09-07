import GmailAPI

/// Selects the messages that may contribute to a conversation snapshot.
public protocol GmailThreadSelector: Sendable {
  /// Returns permitted context when the thread qualifies, or an empty array when it does not.
  /// Throw when selection cannot be determined; callers must preserve existing membership on failure.
  func messages(in thread: GmailThread, matching policy: GmailSyncPolicy) throws -> [GmailMessage]
}
