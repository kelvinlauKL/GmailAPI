import Foundation
import Testing
import GmailAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GmailTransportTests {
  @Test
  func forwardsRequestToCustomTransport() async throws {
    let url = try #require(URL(string: "https://gmail-transport.invalid/profile"))
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    let response = try #require(HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil, headerFields: nil
    ))
    let responseData = Data("profile".utf8)
    let transport = GmailTransport { receivedRequest in
      #expect(receivedRequest.url == url)
      #expect(receivedRequest.httpMethod == "GET")
      #expect(receivedRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
      return (responseData, response)
    }

    let result = try await transport.send(request)

    #expect(result.data == responseData)
    #expect(result.response.statusCode == 200)
  }

  @Test
  func preservesHTTPFailureForClientHandling() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/unavailable"))

    let result = try await GmailTransport(session: session).send(URLRequest(url: url))

    #expect(result.response.statusCode == 503)
    #expect(result.response.value(forHTTPHeaderField: "Retry-After") == "30")
    #expect(result.data == Data("temporarily unavailable".utf8))
  }

  @Test
  func rejectsNonHTTPResponseWithExplanation() async throws {
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://gmail-transport.invalid/non-http"))
    let transport = GmailTransport(session: session)

    await #expect(throws: GmailTransport.TransportError.nonHTTPResponse) {
      try await transport.send(URLRequest(url: url))
    }
    let error: any LocalizedError = GmailTransport.TransportError.nonHTTPResponse
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
      _ = try await GmailTransport(session: session).send(URLRequest(url: url))
      Issue.record("Expected the network failure to propagate.")
    } catch let error as URLError {
      #expect(error.code == .notConnectedToInternet)
    }
  }

  @Test
  func rejectsAlreadyCancelledTaskBeforeSending() async throws {
    let url = try #require(URL(string: "https://gmail-transport.invalid/cancelled"))
    let transport = GmailTransport { _ in
      Issue.record("Cancelled work must not reach the transport.")
      throw CancellationError()
    }

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

  private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      switch url.path {
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
