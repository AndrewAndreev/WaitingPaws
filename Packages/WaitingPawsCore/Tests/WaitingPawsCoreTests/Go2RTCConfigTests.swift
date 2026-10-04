import XCTest
@testable import WaitingPawsCore

final class Go2RTCConfigTests: XCTestCase {
    let config = """
    # Waiting Paws embedded go2rtc
    api:
      listen: "127.0.0.1:11984"
    streams:
      testcam:
        - rtsp://127.0.0.1:8554/testcam
      kitchen: xiaomi://123456:cn@192.168.1.20?did=987&model=chuangmi.camera.v6&subtype=3
      quoted:
      - "ffmpeg:virtual?video#video=h264"
      flow: [rtsp://a/1, 'rtsp://b/2']
    xiaomi:
      "123456": token
    """

    func testBlockList() {
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "testcam"), ["rtsp://127.0.0.1:8554/testcam"])
    }

    func testInlineXiaomiSourceKeepsQuery() {
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "kitchen"),
                       ["xiaomi://123456:cn@192.168.1.20?did=987&model=chuangmi.camera.v6&subtype=3"])
    }

    func testQuotedItemKeepsHash() {
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "quoted"), ["ffmpeg:virtual?video#video=h264"])
    }

    func testFlowList() {
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "flow"), ["rtsp://a/1", "rtsp://b/2"])
    }

    func testOnlyStreamsSection() {
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "listen"), [])
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "123456"), [])
        XCTAssertEqual(Go2RTCClient.streamSources(inConfig: config, stream: "missing"), [])
    }
}
