import Foundation
import Testing
import GmailAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct URLSessionGmailTransportTests {
  @Test
  func forwardsRequestThroughSessionAndReturnsResponse() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let transport: any GmailTransport = URLSessionGmailTransport(session: session)
    let url = try #require(URL(string: "https://gmail-transport.invalid/profile"))
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

    let result = try await transport.send(request)

    #expect(result.data == Data("https://gmail-transport.invalid/profile\nGET\nBearer test-token".utf8))
    #expect(result.response.statusCode == 200)
    #expect(result.response.url == url)
  }

  @Test
  func preservesHTTPFailureForClientHandling() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/unavailable"))

    let result = try await URLSessionGmailTransport(session: session).send(URLRequest(url: url))

    #expect(result.response.statusCode == 503)
    #expect(result.response.value(forHTTPHeaderField: "Retry-After") == "30")
    #expect(result.data == Data("temporarily unavailable".utf8))
  }

  @Test
  func rejectsNonHTTPResponseWithExplanation() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/non-http"))
    let transport = URLSessionGmailTransport(session: session)

    await #expect(throws: URLSessionGmailTransport.TransportError.nonHTTPResponse) {
      try await transport.send(URLRequest(url: url))
    }
    let error: any LocalizedError = URLSessionGmailTransport.TransportError.nonHTTPResponse
    #expect(error.localizedDescription == "The server did not return an HTTP response.")
    #expect(error.failureReason != nil)
    #expect(error.recoverySuggestion != nil)
  }

  @Test
  func propagatesNetworkFailure() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/network-error"))

    do {
      _ = try await URLSessionGmailTransport(session: session).send(URLRequest(url: url))
      Issue.record("Expected the network failure to propagate.")
    } catch let error as URLError {
      #expect(error.code == .notConnectedToInternet)
    }
  }

  @Test
  func rejectsAlreadyCancelledTaskBeforeSending() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/cancelled"))
    let transport = URLSessionGmailTransport(session: session)

    let cancelledTask = Task {
      withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
      return try await transport.send(URLRequest(url: url))
    }

    await #expect(throws: CancellationError.self) {
      try await cancelledTask.value
    }
  }

  private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private extension URLSessionGmailTransportTests {
  final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      switch url.path {
      case "/cancelled":
        Issue.record("An already-cancelled request must not reach URLSession execution.")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        return
      case "/profile":
        guard let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        ) else {
          client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
          return
        }
        // Echo the received request so the test can verify what URLSession sent.
        let requestDetails = [
          url.absoluteString,
          request.httpMethod ?? "",
          request.value(forHTTPHeaderField: "Authorization") ?? ""
        ].joined(separator: "\n")
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(requestDetails.utf8))
      case "/unavailable":
        guard let response = HTTPURLResponse(
          url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "30"]
        ) else {
          client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
          return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("temporarily unavailable".utf8))
      case "/non-http":
        let response = URLResponse(
          url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      default:
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        return
      }
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }
}
