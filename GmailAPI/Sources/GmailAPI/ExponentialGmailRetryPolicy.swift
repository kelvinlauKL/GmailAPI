import Foundation

/// Retries temporary Gmail and connection failures with bounded exponential backoff.
/// Each retry doubles the initial interval and adds zero to one interval of random jitter,
/// capped by `maximumDelay`. Invalid `Retry-After` headers fall back to this backoff.
public struct ExponentialGmailRetryPolicy: GmailRetryPolicy, Equatable {
  /// Retries allowed after the initial request. Zero disables retries.
  public let maximumRetries: Int

  /// The first backoff interval in seconds, before adding jitter.
  public let initialDelay: TimeInterval

  /// The maximum wait per retry, including jitter and `Retry-After`.
  /// A server-requested wait above this limit stops retries instead of shortening the wait.
  public let maximumDelay: TimeInterval

  public init() {
    maximumRetries = Constant.defaultMaximumRetries
    initialDelay = Constant.defaultInitialDelay
    maximumDelay = Constant.defaultMaximumDelay
  }

  public init(
    maximumRetries: Int,
    initialDelay: TimeInterval = Constant.defaultInitialDelay,
    maximumDelay: TimeInterval = Constant.defaultMaximumDelay
  ) throws {
    guard maximumRetries >= 0 else { throw ValidationError.invalidMaximumRetries(maximumRetries) }
    guard initialDelay.isFinite, initialDelay >= Constant.minimumInitialDelay else {
      throw ValidationError.invalidInitialDelay(initialDelay)
    }
    guard maximumDelay.isFinite, maximumDelay >= initialDelay,
      maximumDelay < TimeInterval(Int64.max)
    else { throw ValidationError.invalidMaximumDelay(maximumDelay) }

    self.maximumRetries = maximumRetries
    self.initialDelay = initialDelay
    self.maximumDelay = maximumDelay
  }

  public func waitBeforeRetry(after error: any Error, retryCount: Int) async throws -> Bool {
    try Task.checkCancellation()
    guard let delay = retryDelay(
      after: error, retryCount: retryCount, now: Date(),
      jitterFraction: Double.random(in: Constant.jitterRange)
    ) else { return false }
    try await Task.sleep(for: .seconds(delay))
    return true
  }

  /// Keeps delay calculation deterministic without exposing clock or random dependencies.
  func retryDelay(
    after error: any Error, retryCount: Int, now: Date, jitterFraction: Double
  ) -> TimeInterval? {
    guard retryCount >= 0, retryCount < maximumRetries,
      Constant.jitterRange.contains(jitterFraction)
    else { return nil }

    let requestFailure = error as? GmailRequestFailure
    if let requestFailure {
      guard requestFailure.isRetryable else { return nil }
    } else {
      guard let urlError = error as? URLError, Constant.retryableConnectionErrors.contains(urlError.code)
      else { return nil }
    }

    let backoff = min(initialDelay * pow(Constant.backoffMultiplier, Double(retryCount)), maximumDelay)
    let jitteredDelay = min(backoff + backoff * jitterFraction, maximumDelay)
    guard let headerValue = requestFailure?.retryAfter,
      let retryAfter = GmailRetryAfter(headerValue, relativeTo: now)
    else { return jitteredDelay }
    let delay = max(jitteredDelay, retryAfter.delay)
    return delay <= maximumDelay ? delay : nil
  }
}

public extension ExponentialGmailRetryPolicy {
  enum Constant {
    public static let defaultMaximumRetries: Int = 3
    public static let defaultInitialDelay: TimeInterval = 1
    public static let defaultMaximumDelay: TimeInterval = 60
    public static let minimumInitialDelay: TimeInterval = 1

    fileprivate static let backoffMultiplier: Double = 2
    fileprivate static let jitterRange: ClosedRange<Double> = 0...1
    fileprivate static let retryableConnectionErrors: Set<URLError.Code> = [
      .timedOut, .networkConnectionLost, .cannotConnectToHost,
      .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet
    ]
  }

  enum ValidationError: LocalizedError, Equatable {
    case invalidMaximumRetries(Int)
    case invalidInitialDelay(TimeInterval)
    case invalidMaximumDelay(TimeInterval)

    public var errorDescription: String? {
      "Cannot create the Gmail retry policy with these limits."
    }

    public var failureReason: String? {
      switch self {
      case .invalidMaximumRetries:
        "The maximum retry count cannot be negative."
      case .invalidInitialDelay:
        "The initial delay must be finite and at least \(Constant.minimumInitialDelay) second."
      case .invalidMaximumDelay:
        "The maximum delay must be finite, no shorter than the initial delay, and representable as a sleep duration."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidMaximumRetries:
        "Use zero to disable retries or a positive retry count."
      case .invalidInitialDelay:
        "Set initialDelay to \(Constant.defaultInitialDelay) second or a longer finite interval."
      case .invalidMaximumDelay:
        "Choose a maximumDelay at least as long as initialDelay and less than \(Int64.max) seconds."
      }
    }
  }
}
