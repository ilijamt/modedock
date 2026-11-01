import Foundation
import Testing

@testable import ModeDockCore

/// A server inside the test process: answers each request with the status in its URL
/// (`?status=500`, 204 by default) and keeps what it received, by URL.
private final class FakeServer: URLProtocol, @unchecked Sendable {
    struct Received: Sendable {
        let method: String?
        let contentType: String?
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var received: [URL: Received] = [:]

    static func received(at url: URL) -> Received? { lock.withLock { received[url] } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        // URLSession hands the body over as a stream.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let received = Received(
            method: request.httpMethod, contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body)
        Self.lock.withLock { Self.received[url] = received }

        let status =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "status" }?.value.flatMap(Int.init) ?? 204
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct TelemetryHTTPTests {
    private let sender = HTTPTelemetrySender(configuration: FakeServer.configuration)
    private let report = TelemetryReport(
        install: UUID(), report: UUID(),
        context: TelemetryContext(appVersion: "0.1.0", osVersion: "26.1", language: "en"),
        setup: nil, counts: ["panel.open": 2])

    /// A URL of its own per test, as tests run in parallel.
    private func url(status: Int? = nil) -> URL {
        URL(string: "https://telemetry.test/\(UUID().uuidString)" + (status.map { "?status=\($0)" } ?? ""))!
    }

    @Test func postsTheReportAsJSON() async throws {
        let url = url()
        #expect(await sender.send(report, to: url))
        let received = try #require(FakeServer.received(at: url))
        #expect(received.method == "POST")
        #expect(received.contentType == "application/json")
        #expect(try JSONDecoder().decode(TelemetryReport.self, from: received.body) == report)
    }

    @Test func acceptsAny2xx() async {
        #expect(await sender.send(report, to: url(status: 200)))
        #expect(await sender.send(report, to: url(status: 202)))
    }

    @Test func treatsOtherAnswersAsNotSent() async {
        #expect(await !sender.send(report, to: url(status: 400)))
        #expect(await !sender.send(report, to: url(status: 500)))
        #expect(await !sender.send(report, to: url(status: 301)))
    }
}
