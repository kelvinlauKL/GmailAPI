import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests using URLSession without interpreting status codes or bodies.
public struct URLSessionGmailTransport: GmailTransport {
  private let session: URLSession

  /// Uses an ephemeral session by default. A supplied session remains caller-owned.
  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  /// Returns all HTTP statuses, including failures, for the Gmail client to handle.
  public func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
    try Task.checkCancellation()
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TransportError.nonHTTPResponse
    }
    return (data, httpResponse)
  }
}

extension URLSessionGmailTransport {
  public enum TransportError: LocalizedError, Equatable {
    case nonHTTPResponse

    public var errorDescription: String? {
      "The server did not return an HTTP response."
    }

    public var failureReason: String? {
      "An HTTP status code and headers are required to interpret a Gmail response."
    }

    public var recoverySuggestion: String? {
      "Use Gmail's HTTPS API endpoint and an HTTP-compatible session or transport."
    }
  }
}
