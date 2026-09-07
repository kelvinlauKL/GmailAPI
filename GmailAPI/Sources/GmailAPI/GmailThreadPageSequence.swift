import Foundation

/// Fetches thread-list pages on demand, including pages with no thread entries.
/// Each iterator starts at the supplied request's page token and makes its own requests.
/// Pages are not prefetched or retained; requested tokens are remembered to detect cycles.
public struct GmailThreadPageSequence: AsyncSequence, Sendable {
  public typealias Element = GmailThreadListResponse

  private let client: GmailClient
  private let request: GmailThreadListRequest

  public init(client: GmailClient, request: GmailThreadListRequest) {
    self.client = client
    self.request = request
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(client: client, request: request)
  }
}

public extension GmailThreadPageSequence {
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    private let client: GmailClient
    private var nextRequest: GmailThreadListRequest?
    private var requestedPageTokens: Set<String> = []

    fileprivate init(client: GmailClient, request: GmailThreadListRequest) {
      self.client = client
      nextRequest = request
    }

    /// Fetches one page, using the client's authentication and retry policy.
    /// A missing or empty continuation token ends iteration after yielding that page.
    /// After an error or cancellation, subsequent calls return `nil`.
    public mutating func next() async throws -> GmailThreadListResponse? {
      guard let request = nextRequest else { return nil }
      // Leave the iterator finished unless this request supplies another page.
      nextRequest = nil
      try Task.checkCancellation()
      if let pageToken = request.pageToken, !requestedPageTokens.insert(pageToken).inserted {
        throw PaginationError.repeatedPageToken
      }

      let page = try await client.listThreads(request)
      if let pageToken = page.nextPageToken, !pageToken.isEmpty {
        nextRequest = try GmailThreadListRequest(
          q: request.q, maxResults: request.maxResults, pageToken: pageToken,
          labelIds: request.labelIds, includeSpamTrash: request.includeSpamTrash
        )
      }
      return page
    }
  }

  enum PaginationError: LocalizedError, Equatable {
    case repeatedPageToken

    public var errorDescription: String? {
      "Gmail thread pagination could not continue."
    }

    public var failureReason: String? {
      "Gmail returned a continuation token for a page already requested."
    }

    public var recoverySuggestion: String? {
      "Restart the thread listing with the original filters and deduplicate previously processed results."
    }
  }
}
