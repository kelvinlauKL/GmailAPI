import Foundation

/// Fetches history pages on demand while preserving the original starting history ID.
/// Each iterator starts at the supplied request's page token and makes its own requests.
/// Pages are not prefetched or retained; requested tokens are remembered to detect cycles.
/// Save the final page's `historyId` only after every page has been processed successfully.
public struct GmailHistoryPageSequence: AsyncSequence, Sendable {
  public typealias Element = GmailHistoryListResponse

  private let client: GmailClient
  private let request: GmailHistoryListRequest

  public init(client: GmailClient, request: GmailHistoryListRequest) {
    self.client = client
    self.request = request
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(client: client, request: request)
  }
}

public extension GmailHistoryPageSequence {
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    private let client: GmailClient
    private var nextRequest: GmailHistoryListRequest?
    private var requestedPageTokens: Set<String> = []

    fileprivate init(client: GmailClient, request: GmailHistoryListRequest) {
      self.client = client
      nextRequest = request
    }

    /// Fetches one page, using the client's authentication and retry policy.
    /// Empty pages are yielded; a missing or empty continuation token marks the last page.
    /// Errors, including expired history, propagate and finish this iterator.
    /// After an error or cancellation, subsequent calls return `nil`.
    public mutating func next() async throws -> GmailHistoryListResponse? {
      guard let request = nextRequest else { return nil }
      // Leave the iterator finished unless this request supplies another page.
      nextRequest = nil
      try Task.checkCancellation()
      if let pageToken = request.pageToken, !requestedPageTokens.insert(pageToken).inserted {
        throw PaginationError.repeatedPageToken
      }

      let page = try await client.listHistory(request)
      if let pageToken = page.nextPageToken, !pageToken.isEmpty {
        nextRequest = try GmailHistoryListRequest(
          startHistoryId: request.startHistoryId, maxResults: request.maxResults,
          pageToken: pageToken, labelId: request.labelId, historyTypes: request.historyTypes
        )
      }
      return page
    }
  }

  enum PaginationError: LocalizedError, Equatable {
    case repeatedPageToken

    public var errorDescription: String? {
      "Gmail history pagination could not continue."
    }

    public var failureReason: String? {
      "Gmail returned a continuation token for a page already requested."
    }

    public var recoverySuggestion: String? {
      "Restart history pagination from the last committed history ID and deduplicate previously processed changes."
    }
  }
}
