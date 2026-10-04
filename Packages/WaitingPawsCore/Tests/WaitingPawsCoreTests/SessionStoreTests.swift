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
}
