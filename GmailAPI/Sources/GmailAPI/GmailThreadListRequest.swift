import Foundation

/// Search and pagination options for Gmail's `users.threads.list` endpoint.
public struct GmailThreadListRequest: Equatable, Sendable {
  /// Gmail search syntax, such as `from:manager@example.com`.
  public let q: String?

  /// Maximum threads per page. This request accepts values from 1 through 500.
  public let maxResults: Int

  /// The opaque `nextPageToken` returned by the preceding response.
  public let pageToken: String?

  /// Restrict results to threads matching all of these label IDs.
  public let labelIds: [String]

  /// Whether results may include spam and trash.
  public let includeSpamTrash: Bool

  public init(
    q: String? = nil,
    maxResults: Int = 100,
    pageToken: String? = nil,
    labelIds: [String] = [],
    includeSpamTrash: Bool = false
  ) throws {
    guard (1...500).contains(maxResults) else {
      throw ValidationError.invalidMaxResults(maxResults)
    }

    self.q = q
    self.maxResults = maxResults
    self.pageToken = pageToken
    self.labelIds = labelIds
    self.includeSpamTrash = includeSpamTrash
  }

  var queryItems: [URLQueryItem] {
    var items = [
      URLQueryItem(name: "maxResults", value: String(maxResults)),
      URLQueryItem(name: "includeSpamTrash", value: String(includeSpamTrash))
    ]
    if let q {
      items.append(URLQueryItem(name: "q", value: q))
    }
    if let pageToken {
      items.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    items.append(contentsOf: labelIds.map { URLQueryItem(name: "labelIds", value: $0) })
    return items
  }

  public enum ValidationError: Error, Equatable {
    case invalidMaxResults(Int)
  }
}
