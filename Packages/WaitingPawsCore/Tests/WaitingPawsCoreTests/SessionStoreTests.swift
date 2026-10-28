import XCTest
@testable import WaitingPawsCore

final class SessionStoreTests: XCTestCase {
    func testRecordingNamesDoNotCollideAndStandaloneOnesAreListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let plan = TrainingPlan(title: "Запись")
        let date = Date(timeIntervalSince1970: 1_791_000_000)

        let first = store.newRecordingURL(for: plan, at: date)
        FileManager.default.createFile(atPath: first.path, contents: Data([1]))
        let second = store.newRecordingURL(for: plan, at: date)
        XCTAssertNotEqual(first, second)
        FileManager.default.createFile(atPath: second.path, contents: Data([1]))

        let record = TrainingRecord(plan: plan, startedAt: date, finishedAt: date, events: [], results: [],
                                    recordingFileName: first.lastPathComponent)
        XCTAssertEqual(store.standaloneRecordings(besides: [record]).map(\.lastPathComponent), [second.lastPathComponent])
    }

    /// A history file copied from elsewhere must not point deleting or sharing outside `Recordings`.
    func testRecordingFileNameIsOnlyABareMP4Name() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let plan = TrainingPlan(title: "Тренировка")
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let outside = root.appendingPathComponent("outside.mp4")
        let config = root.appendingPathComponent("go2rtc.yaml")
        FileManager.default.createFile(atPath: outside.path, contents: Data([1]))
        FileManager.default.createFile(atPath: config.path, contents: Data([1]))

        for name in ["../outside.mp4", "../go2rtc.yaml", "..", ".", "", "/tmp/outside.mp4", "sub/../../outside.mp4",
                     "..\\outside.mp4", "video.mov", "C:outside.mp4", ".mp4", "mp4", "line\nbreak.mp4", "nul\0.mp4"] {
            let record = TrainingRecord(plan: plan, startedAt: date, finishedAt: date, events: [], results: [],
                                        recordingFileName: name)
            XCTAssertNil(store.recordingURL(for: record), name)
            store.delete(record, includingRecording: true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))

        let video = store.newRecordingURL(for: plan, at: date)
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let record = TrainingRecord(plan: plan, startedAt: date, finishedAt: date, events: [], results: [],
                                    recordingFileName: video.lastPathComponent)
        XCTAssertEqual(store.recordingURL(for: record), video)
        store.delete(record, includingRecording: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))

        // The extension in another case, as on Windows.
        let upper = store.recordingsDirectory.appendingPathComponent("clip.MP4")
        FileManager.default.createFile(atPath: upper.path, contents: Data([1]))
        let upperRecord = TrainingRecord(plan: plan, startedAt: date, finishedAt: date, events: [], results: [],
                                         recordingFileName: "clip.MP4")
        XCTAssertEqual(store.recordingURL(for: upperRecord), upper)
    }
}
