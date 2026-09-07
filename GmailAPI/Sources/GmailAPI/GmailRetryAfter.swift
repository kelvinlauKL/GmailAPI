import Foundation

/// The minimum wait requested by a `Retry-After` response header.
public struct GmailRetryAfter: Equatable, Sendable {
  /// Seconds to wait from the supplied reference date, with past dates clamped to zero.
  /// Extremely large integer values are rounded upward or represented as infinity.
  public let delay: TimeInterval

  public init?(_ headerValue: String, relativeTo referenceDate: Date = Date()) {
    let value = headerValue.trimmingCharacters(in: Constant.optionalWhitespace)
    guard !value.isEmpty else { return nil }
    if value.utf8.allSatisfy(Constant.asciiDigits.contains) {
      let seconds = TimeInterval(value) ?? .infinity
      delay = seconds < Constant.exactIntegerLimit ? seconds : seconds.nextUp
      return
    }
    guard referenceDate.timeIntervalSince1970.isFinite,
      let date = Self.parseHTTPDate(value, relativeTo: referenceDate)
    else { return nil }
    delay = max(0, date.timeIntervalSince(referenceDate))
  }

  private static func parseHTTPDate(_ value: String, relativeTo referenceDate: Date) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = Constant.gmt
    for format in DateFormat.allCases {
      guard value.range(of: format.pattern, options: .regularExpression) != nil else { continue }
      var normalizedValue = format == .asctime
        ? value.replacingOccurrences(of: "  ", with: " 0") : value
      let hasLeapSecond = normalizedValue.contains(":60 ")
      if hasLeapSecond {
        normalizedValue = normalizedValue.replacingOccurrences(of: ":60 ", with: ":59 ")
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = calendar
      formatter.timeZone = Constant.gmt
      formatter.isLenient = false
      formatter.dateFormat = format.rawValue
      formatter.twoDigitStartDate = calendar.date(
        byAdding: .year, value: -Constant.twoDigitYearWindow, to: referenceDate
      )?.addingTimeInterval(Constant.timestampResolution)
      guard var date = formatter.date(from: normalizedValue) else { continue }
      if format == .rfc850,
        let futureLimit = calendar.date(byAdding: .year, value: Constant.twoDigitYearWindow, to: referenceDate),
        date > futureLimit
      {
        guard let previousCentury = calendar.date(byAdding: .year, value: -Constant.yearsPerCentury, to: date)
        else { continue }
        date = previousCentury
      }
      guard formatter.string(from: date) == normalizedValue else { continue }
      return hasLeapSecond ? date.addingTimeInterval(Constant.leapSecondAdjustment) : date
    }
    return nil
  }
}

private extension GmailRetryAfter {
  enum DateFormat: String, CaseIterable {
    case preferred = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    case rfc850 = "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"
    case asctime = "EEE MMM dd HH:mm:ss yyyy"

    var pattern: String {
      switch self {
      case .preferred:
        #"\A[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT\z"#
      case .rfc850:
        #"\A[A-Z][a-z]+, [0-9]{2}-[A-Z][a-z]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT\z"#
      case .asctime:
        #"\A[A-Z][a-z]{2} [A-Z][a-z]{2} (?:[0-9]{2}| [0-9]) [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\z"#
      }
    }
  }

  enum Constant {
    static let optionalWhitespace: CharacterSet = CharacterSet(charactersIn: " \t")
    static let asciiDigits: ClosedRange<UInt8> = 48...57
    static let exactIntegerLimit: TimeInterval = 9_007_199_254_740_992
    static let twoDigitYearWindow: Int = 50
    static let yearsPerCentury: Int = 100
    static let timestampResolution: TimeInterval = 1
    static let leapSecondAdjustment: TimeInterval = 1
    static let gmt: TimeZone = TimeZone(secondsFromGMT: 0)!
  }
}
