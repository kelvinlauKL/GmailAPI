import Foundation

/// Versioned mailbox-selection settings for the synchronization engine.
/// A thread qualifies when at least one permitted message meets both date and label filters.
/// This value describes selection; it does not fetch or evaluate messages itself.
public struct GmailSyncPolicy: Codable, Equatable, Sendable {
  /// A host-managed version. Increment it whenever mailbox-selection rules change.
  public let version: Int

  /// An inclusive, fixed lower bound on Gmail's internal message date.
  /// `nil` imposes no date bound. The bound does not move automatically between passes.
  public let oldestMessageDate: Date?

  /// Every required label must be present on the same qualifying message.
  /// IDs are deduplicated and sorted without changing their individual values.
  public let requiredLabelIds: [String]

  /// Whether messages in spam or trash are permitted, including as conversation context.
  public let includeSpamTrash: Bool

  /// Whether draft messages are permitted, including as conversation context.
  public let includeDrafts: Bool

  public init(
    version: Int,
    oldestMessageDate: Date? = nil,
    requiredLabelIds: [String] = [],
    includeSpamTrash: Bool = false,
    includeDrafts: Bool = false
  ) throws {
    guard version >= Constant.minimumVersion else { throw ValidationError.invalidVersion(version) }
    if let oldestMessageDate, !oldestMessageDate.timeIntervalSince1970.isFinite {
      throw ValidationError.invalidOldestMessageDate
    }
    guard requiredLabelIds.allSatisfy({ labelID in
      !labelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else { throw ValidationError.emptyRequiredLabelID }

    self.version = version
    self.oldestMessageDate = oldestMessageDate
    self.requiredLabelIds = Array(Set(requiredLabelIds)).sorted()
    self.includeSpamTrash = includeSpamTrash
    self.includeDrafts = includeDrafts
  }

  /// Restores selection settings without bypassing validation or label canonicalization.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      version: container.decode(Int.self, forKey: .version),
      oldestMessageDate: container.decodeIfPresent(Date.self, forKey: .oldestMessageDate),
      requiredLabelIds: container.decode([String].self, forKey: .requiredLabelIds),
      includeSpamTrash: container.decode(Bool.self, forKey: .includeSpamTrash),
      includeDrafts: container.decode(Bool.self, forKey: .includeDrafts)
    )
  }
}

public extension GmailSyncPolicy {
  enum Constant {
    public static let minimumVersion: Int = 1
  }

  enum ValidationError: LocalizedError, Equatable {
    case invalidVersion(Int)
    case invalidOldestMessageDate
    case emptyRequiredLabelID

    public var errorDescription: String? {
      "Cannot create the Gmail synchronization policy."
    }

    public var failureReason: String? {
      switch self {
      case .invalidVersion: "The selection-policy version must be positive."
      case .invalidOldestMessageDate: "The oldest message date is not a finite instant."
      case .emptyRequiredLabelID: "A required label ID is empty or contains only whitespace."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidVersion:
        "Use a version of at least \(Constant.minimumVersion) and increment it when selection rules change."
      case .invalidOldestMessageDate:
        "Supply a fixed, finite oldestMessageDate, or nil to include all dates."
      case .emptyRequiredLabelID:
        "Supply label IDs returned by Gmail, or an empty array to impose no label filter."
      }
    }
  }
}
