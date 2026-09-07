import Foundation

/// Work limits for one synchronization pass, independent of mailbox selection.
/// These values configure the engine; constructing a budget does not execute or limit requests.
public struct GmailSyncBudget: Codable, Equatable, Sendable {
  /// Maximum thread-list or history pages to attempt during discovery.
  public let maximumDiscoveryPages: Int

  /// Maximum conversation fetch jobs to attempt, including jobs that fail.
  /// Retries within each request are governed by the Gmail client's retry policy.
  public let maximumThreadFetches: Int

  /// Maximum simultaneous conversation fetches within this pass.
  /// The host remains responsible for limits shared across accounts or concurrent passes.
  public let maximumConcurrentThreadFetches: Int

  public init(
    maximumDiscoveryPages: Int = Constant.defaultMaximumDiscoveryPages,
    maximumThreadFetches: Int = Constant.defaultMaximumThreadFetches,
    maximumConcurrentThreadFetches: Int = Constant.defaultMaximumConcurrentThreadFetches
  ) throws {
    guard maximumDiscoveryPages >= Constant.minimumWorkLimit else {
      throw ValidationError.invalidDiscoveryPageLimit(maximumDiscoveryPages)
    }
    guard maximumThreadFetches >= Constant.minimumWorkLimit else {
      throw ValidationError.invalidThreadFetchLimit(maximumThreadFetches)
    }
    guard maximumConcurrentThreadFetches >= Constant.minimumWorkLimit else {
      throw ValidationError.invalidConcurrencyLimit(maximumConcurrentThreadFetches)
    }
    self.maximumDiscoveryPages = maximumDiscoveryPages
    self.maximumThreadFetches = maximumThreadFetches
    self.maximumConcurrentThreadFetches = maximumConcurrentThreadFetches
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumDiscoveryPages: container.decode(Int.self, forKey: .maximumDiscoveryPages),
      maximumThreadFetches: container.decode(Int.self, forKey: .maximumThreadFetches),
      maximumConcurrentThreadFetches: container.decode(Int.self, forKey: .maximumConcurrentThreadFetches)
    )
  }
}

public extension GmailSyncBudget {
  enum Constant {
    public static let minimumWorkLimit: Int = 1
    public static let defaultMaximumDiscoveryPages: Int = 10
    public static let defaultMaximumThreadFetches: Int = 100
    public static let defaultMaximumConcurrentThreadFetches: Int = 4
  }

  enum ValidationError: LocalizedError, Equatable {
    case invalidDiscoveryPageLimit(Int)
    case invalidThreadFetchLimit(Int)
    case invalidConcurrencyLimit(Int)

    public var errorDescription: String? {
      "Cannot create the Gmail synchronization budget."
    }

    public var failureReason: String? {
      switch self {
      case .invalidDiscoveryPageLimit: "The discovery page limit must be positive."
      case .invalidThreadFetchLimit: "The conversation fetch limit must be positive."
      case .invalidConcurrencyLimit: "The concurrent conversation fetch limit must be positive."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .invalidDiscoveryPageLimit:
        "Set maximumDiscoveryPages to at least \(Constant.minimumWorkLimit)."
      case .invalidThreadFetchLimit:
        "Set maximumThreadFetches to at least \(Constant.minimumWorkLimit)."
      case .invalidConcurrencyLimit:
        "Set maximumConcurrentThreadFetches to at least \(Constant.minimumWorkLimit)."
      }
    }
  }
}
