import XCTest
@testable import WaitingPawsCore

final class MP4FragmentScannerTests: XCTestCase {
    private func box(_ type: String, body: Int) -> Data {
        var data = Data()
        let size = UInt32(8 + body)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
        data.append(contentsOf: Array(type.utf8))
        data.append(Data(repeating: 0x6D, count: body)) // bytes that spell "moof" nowhere useful
        return data
    }

    /// go2rtc's stream.mp4: the init segment at once, the first fragment with the next keyframe.
    func testInitSegmentIsNotAFragment() {
        var scanner = MP4FragmentScanner()
        XCTAssertFalse(scanner.feed(box("ftyp", body: 16) + box("moov", body: 700)))
        XCTAssertTrue(scanner.feed(box("moof", body: 100) + box("mdat", body: 5000)))
        XCTAssertTrue(scanner.sawFragment)
    }

    /// Network chunks cut boxes (and their headers) anywhere.
    func testChunksSplitAnywhere() {
        let stream = box("ftyp", body: 16) + box("moov", body: 1300) + box("moof", body: 90)
        let fragmentStart = stream.count - 98
        for chunk in [1, 3, 7, 64, 1000] {
            var scanner = MP4FragmentScanner()
            var seenAt: Int?
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunk, stream.count)
                if scanner.feed(stream.subdata(in: offset..<end)), seenAt == nil { seenAt = offset }
                offset = end
            }
            XCTAssertNotNil(seenAt, "chunk \(chunk)")
            XCTAssertLessThanOrEqual(seenAt!, fragmentStart + 7, "chunk \(chunk)")
            XCTAssertGreaterThan(seenAt! + chunk, fragmentStart, "chunk \(chunk)")
        }
    }

    /// A box body that happens to contain "moof" is skipped, not read as a header.
    func testBodyBytesAreSkipped() {
        var moov = box("moov", body: 0)
        moov[3] = 8 + 12
        moov.append(contentsOf: Array("....moof....".utf8))
        var scanner = MP4FragmentScanner()
        XCTAssertFalse(scanner.feed(box("ftyp", body: 8) + moov))
    }

    /// A 64-bit box size (size field 1) is followed by the real size.
    func testLargeSize() {
        var large = Data([0, 0, 0, 1]) + Data(Array("free".utf8))
        large.append(contentsOf: withUnsafeBytes(of: UInt64(16 + 4).bigEndian, Array.init))
        large.append(Data(repeating: 0, count: 4))
        var scanner = MP4FragmentScanner()
        XCTAssertFalse(scanner.feed(large))
        XCTAssertTrue(scanner.feed(box("moof", body: 8)))
    }
}
