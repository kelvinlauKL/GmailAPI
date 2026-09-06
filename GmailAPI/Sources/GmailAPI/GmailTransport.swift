import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests without interpreting Gmail status codes or decoding bodies.
public struct GmailTransport: Sendable {
  private let sendRequest: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Uses an ephemeral session by default. A supplied session remains caller-owned.
  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    sendRequest = { request in
      let (data, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw TransportError.nonHTTPResponse
      }
      return (data, httpResponse)
    }
  }

  /// Supplies custom HTTP execution, such as an in-memory test implementation.
  public init(
    sendRequest: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  ) {
    self.sendRequest = sendRequest
  }

  /// Returns all HTTP statuses, including failures, for the Gmail client to handle.
  public func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
    try Task.checkCancellation()
    return try await sendRequest(request)
  }

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
