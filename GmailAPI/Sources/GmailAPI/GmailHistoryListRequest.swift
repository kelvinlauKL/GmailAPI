import Foundation

/// Sync, filter, and pagination options for Gmail's `users.history.list` endpoint.
public struct GmailHistoryListRequest: Equatable, Sendable {
  /// Return changes after this opaque history ID from a previous Gmail response.
  /// Gmail determines whether the ID is still valid for incremental sync.
  public let startHistoryId: String

  /// Maximum history records per page, within the bounds defined by `Constant`.
  public let maxResults: Int

  /// The opaque `nextPageToken` returned by the preceding response.
  public let pageToken: String?

  /// Restrict results to messages with this label ID, when provided.
  public let labelId: String?

  /// Restrict results to these change types. An empty array applies no type filter.
  public let historyTypes: [HistoryType]

  public init(
    startHistoryId: String,
    maxResults: Int = Constant.defaultPageSize,
    pageToken: String? = nil,
    labelId: String? = nil,
    historyTypes: [HistoryType] = []
  ) throws {
    guard !startHistoryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.missingStartHistoryID
    }
    guard (Constant.minimumPageSize...Constant.maximumPageSize).contains(maxResults) else {
      throw ValidationError.invalidMaxResults(maxResults)
    }

    self.startHistoryId = startHistoryId
    self.maxResults = maxResults
    self.pageToken = pageToken
    self.labelId = labelId
    self.historyTypes = historyTypes
  }

  var queryItems: [URLQueryItem] {
    var queryItems = [
      URLQueryItem(name: "startHistoryId", value: startHistoryId),
      URLQueryItem(name: "maxResults", value: String(maxResults))
    ]
    if let pageToken {
      queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    if let labelId {
      queryItems.append(URLQueryItem(name: "labelId", value: labelId))
    }
    queryItems.append(contentsOf: historyTypes.map { historyType in
      URLQueryItem(name: "historyTypes", value: historyType.rawValue)
    })
    return queryItems
  }
}

public extension GmailHistoryListRequest {
  /// The kinds of mailbox changes that a history request can select.
  enum HistoryType: String, CaseIterable, Sendable {
    case messageAdded
    case messageDeleted
    case labelAdded
    case labelRemoved
  }

  enum Constant {
    public static let minimumPageSize: Int = 1
    public static let maximumPageSize: Int = 500
    public static let defaultPageSize: Int = 100
  }

  enum ValidationError: LocalizedError, Equatable {
    case missingStartHistoryID
    case invalidMaxResults(Int)

    public var errorDescription: String? {
      switch self {
      case .missingStartHistoryID:
        return "Cannot list history without a starting history ID."
      case .invalidMaxResults(let invalidPageSize):
        return "Cannot list history with a page size of \(invalidPageSize)."
      }
    }

    public var failureReason: String? {
      switch self {
      case .missingStartHistoryID:
        return "The starting history ID is empty or contains only whitespace."
      case .invalidMaxResults:
        return "The page size must be positive and cannot exceed Gmail's limit of \(Constant.maximumPageSize) history records."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .missingStartHistoryID:
        return "Pass a historyId from a previous Gmail response as startHistoryId."
      case .invalidMaxResults:
        return "Set maxResults to a value from \(Constant.minimumPageSize) through \(Constant.maximumPageSize) and try again."
      }
    }
  }
}
