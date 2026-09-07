import Foundation
import Testing
import GmailAPI

struct GmailRetryAfterTests {
  @Test(arguments: [("0", 0.0), ("120", 120.0), ("00120", 120.0), (" \t120\t ", 120.0)])
  func parsesWholeSeconds(header: String, expectedDelay: TimeInterval) throws {
    let retryAfter = try #require(GmailRetryAfter(header))
    #expect(retryAfter.delay == expectedDelay)
  }

  @Test(arguments: [
    "Sun, 06 Nov 1994 08:49:37 GMT",
    "Sunday, 06-Nov-94 08:49:37 GMT",
    "Sun Nov  6 08:49:37 1994",
    "Sun Nov 06 08:49:37 1994"
  ])
  func parsesAllHTTPDateFormats(header: String) throws {
    let referenceDate = Date(timeIntervalSince1970: 784_111_717)
    let retryAfter = try #require(GmailRetryAfter(header, relativeTo: referenceDate))
    #expect(retryAfter.delay == 60)
  }

  @Test
  func clampsPastDatesToZero() throws {
    let referenceDate = Date(timeIntervalSince1970: 784_111_800)
    let retryAfter = try #require(GmailRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", relativeTo: referenceDate))
    #expect(retryAfter.delay == 0)
  }

  @Test
  func appliesTheFiftyYearWindowToTwoDigitYears() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_793_954_977)
    let oldDate = try #require(GmailRetryAfter("Sunday, 06-Nov-94 08:49:37 GMT", relativeTo: referenceDate))
    let boundaryDate = try #require(GmailRetryAfter("Friday, 06-Nov-76 08:49:37 GMT", relativeTo: referenceDate))
    let pastCenturyDate = try #require(GmailRetryAfter(
      "Saturday, 06-Nov-76 08:49:37 GMT", relativeTo: referenceDate.addingTimeInterval(-1)
    ))
    #expect(oldDate.delay == 0)
    #expect(boundaryDate.delay == 3_371_878_177 - referenceDate.timeIntervalSince1970)
    #expect(pastCenturyDate.delay == 0)
  }

  @Test
  func accountsForLeapSeconds() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_483_228_799)
    let retryAfter = try #require(GmailRetryAfter("Sat, 31 Dec 2016 23:59:60 GMT", relativeTo: referenceDate))
    #expect(retryAfter.delay == 1)
  }

  @Test
  func preservesOversizedDelaysInsteadOfTreatingThemAsMissing() throws {
    let oversized = try #require(GmailRetryAfter(String(repeating: "9", count: 400)))
    let rounded = try #require(GmailRetryAfter("9007199254740993"))
    let leadingZeros = try #require(GmailRetryAfter(String(repeating: "0", count: 400) + "120"))
    #expect(oversized.delay == .infinity)
    #expect(rounded.delay >= 9_007_199_254_740_994)
    #expect(leadingZeros.delay == 120)
  }

  @Test(arguments: [
    "", " \t", "+1", "-1", "1.5", "1e3", "NaN", "inf", "١٢", "12\n", "12, 13",
    "Sun, 06 Nov 1994 08:49:37 PST", "Sun, 31 Feb 1994 08:49:37 GMT",
    "Mon, 06 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 25:49:37 GMT",
    "Sun, 06 Nov 1994 08:49:61 GMT", "Sun, 06 Nov 1994 08:49:37 GMT trailing",
    "Sun, 06 Nov 1994 08:49:37 GMT\n", "Sun,  06 Nov 1994 08:49:37 GMT"
  ])
  func rejectsMalformedHeaders(header: String) {
    #expect(GmailRetryAfter(header) == nil)
  }
}
