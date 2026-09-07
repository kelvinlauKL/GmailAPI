/// Decides whether a failed request should be retried and waits before allowing it.
public protocol GmailRetryPolicy: Sendable {
  /// Receives a `GmailRequestFailure` for an HTTP failure or the original transport error.
  /// `retryCount` is the number of transient retries already performed for this operation;
  /// zero identifies the first retry. Authentication refreshes do not count toward it.
  /// Return `true` after waiting to retry, or `false` to propagate the failure.
  /// Implementations must bound retries, honor `Retry-After`, and support cancellation.
  func waitBeforeRetry(after error: any Error, retryCount: Int) async throws -> Bool
}
