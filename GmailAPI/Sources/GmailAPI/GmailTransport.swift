import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests without interpreting Gmail status codes or decoding bodies.
public protocol GmailTransport: Sendable {
  /// Returns all HTTP statuses, including failures, for the Gmail client to handle.
  /// Implementations should respect task cancellation and propagate network failures.
  func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}
