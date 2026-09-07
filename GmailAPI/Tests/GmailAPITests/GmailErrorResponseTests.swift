import Foundation
import Testing
import GmailAPI

struct GmailErrorResponseTests {
  @Test
  func decodesDiagnosticsAndPreservesReasonOrder() throws {
    let json = """
      {
        "error": {
          "code":400,
          "message":"A request parameter is invalid.",
          "errors":[
            {
              "reason":"badRequest",
              "domain":"global",
              "message":"Check the search expression.",
              "location":"q",
              "locationType":"parameter",
              "futureField":true
            },
            {"reason":"futureReason"}
          ],
          "futureField":true
        },
        "futureField":true
      }
      """
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    let errors = try #require(response.error.errors)
    let firstError = try #require(errors.first)

    #expect(response.error.code == 400)
    #expect(response.error.message == "A request parameter is invalid.")
    #expect(errors.map(\.reason) == ["badRequest", "futureReason"])
    #expect(firstError.domain == "global")
    #expect(firstError.message == "Check the search expression.")
    #expect(firstError.location == "q")
    #expect(firstError.locationType == "parameter")
  }

  @Test(arguments: [
    #"{"error":{"code":403}}"#,
    #"{"error":{"code":403,"message":null,"errors":null}}"#
  ])
  func preservesMissingOrNullDiagnostics(json: String) throws {
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))

    #expect(response.error.code == 403)
    #expect(response.error.message == nil)
    #expect(response.error.errors == nil)
  }

  @Test
  func preservesExplicitEmptyErrorList() throws {
    let json = #"{"error":{"code":503,"errors":[]}}"#
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))

    #expect(response.error.code == 503)
    #expect(response.error.errors == [])
  }

  @Test(arguments: [
    #"{"reason":"userRateLimitExceeded"}"#,
    #"{"reason":"userRateLimitExceeded","domain":null,"message":null,"location":null,"locationType":null}"#
  ])
  func acceptsReasonsWithoutDiagnosticMetadata(entryJSON: String) throws {
    let json = """
      {"error":{"code":403,"errors":[\(entryJSON)]}}
      """
    let response = try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    let entry = try #require(response.error.errors?.first)

    #expect(entry.reason == "userRateLimitExceeded")
    #expect(entry.domain == nil)
    #expect(entry.message == nil)
    #expect(entry.location == nil)
    #expect(entry.locationType == nil)
  }

  @Test(arguments: [
    "{}", #"{"error":null}"#, #"{"error":"invalid_grant"}"#, #"{"error":[]}"#,
    #"{"error":{}}"#, #"{"error":{"code":null}}"#,
    #"{"error":{"code":"403"}}"#, #"{"error":{"code":true}}"#
  ])
  func rejectsMissingOrMalformedErrorEnvelope(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    #"{"error":{"code":403,"message":123}}"#,
    #"{"error":{"code":403,"errors":{}}}"#,
    #"{"error":{"code":403,"errors":[null]}}"#,
    #"{"error":{"code":403,"errors":[{}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":null}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":123}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":"badRequest","domain":false}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":"badRequest","message":{}}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":"badRequest","location":123}]}}"#,
    #"{"error":{"code":403,"errors":[{"reason":"badRequest","locationType":[]}]}}"#
  ])
  func rejectsMalformedDiagnostics(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(GmailErrorResponse.self, from: Data(json.utf8))
    }
  }
}
