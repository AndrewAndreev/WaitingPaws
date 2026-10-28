import XCTest
@testable import WaitingPawsCore

final class Go2RTCURLTests: XCTestCase {
    let client = Go2RTCClient(server: Go2RTCServer(baseURL: URL(string: "http://127.0.0.1:11984/")!,
                                                   username: "user", password: "it's"))
    /// Values go2rtc must get back exactly as sent.
    let values = ["rtsp://admin:p+ss@192.168.1.20/live", "rtsp://cam/live;ch=1", "a&b=c", "it's", "with space",
                  "Гостиная", "100%"]

    /// The query as go2rtc reads it (Go's `url.ParseQuery`): `+` is a space, a pair with a raw `;` is dropped.
    private func goQuery(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (url.query(percentEncoded: true) ?? "").split(separator: "&") where !pair.contains(";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    func testQueryValuesSurviveGoParsing() {
        for value in values {
            let url = client.url(path: "api/streams", query: ["name": "cam", "src": value])
            XCTAssertEqual(goQuery(url), ["name": "cam", "src": value], value)
        }
    }

    func testPlayerSocketURLIsEncodedAndHasNoQuote() {
        for value in values {
            let url = client.playerSocketURL(stream: value)
            XCTAssertEqual(url.scheme, "ws")
            XCTAssertEqual(url.path, "/api/ws")
            XCTAssertEqual(goQuery(url), ["src": value], value)
            XCTAssertFalse(url.query(percentEncoded: true)!.contains("'"), value)
        }
        XCTAssertTrue(client.playerSocketURL(stream: "cam'1").query(percentEncoded: true)!.hasSuffix("cam%271"))
    }

    func testFormEncodeMatchesQueryEncoding() {
        XCTAssertEqual(Go2RTCClient.formEncode(["src": "p+ss;x 'y' Гос"]), "src=p%2Bss%3Bx%20%27y%27%20%D0%93%D0%BE%D1%81")
        XCTAssertEqual(Go2RTCClient.percentEncode("A-z_0.9~"), "A-z_0.9~")
    }
}
