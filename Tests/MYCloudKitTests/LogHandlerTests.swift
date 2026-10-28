import XCTest
@testable import MYCloudKit

final class LogHandlerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var entries: [(level: MYSyncEngine.LogLevel, message: String, error: Error?)] = []
    }

    func testSendsMessagesAtOrAboveTheLevelToTheHandler() {
        let recorder = Recorder()
        let logger = MYSyncEngine.Logger(currentLevel: .warning) { level, message, error in
            recorder.entries.append((level, message, error))
        }
        let error = NSError(domain: "test", code: 1)

        logger.log("skipped", level: .info)
        logger.log("kept", level: .warning)
        logger.log("failed", error: error)

        XCTAssertEqual(recorder.entries.map(\.message), ["kept", "failed"])
        XCTAssertEqual(recorder.entries.map(\.level), [.warning, .error])
        XCTAssertNil(recorder.entries[0].error)
        XCTAssertEqual(recorder.entries[1].error as NSError?, error)
    }

    func testLevelNoneSendsNothing() {
        let recorder = Recorder()
        let logger = MYSyncEngine.Logger(currentLevel: .none) { level, message, error in
            recorder.entries.append((level, message, error))
        }

        logger.log("failed", error: NSError(domain: "test", code: 1))

        XCTAssertTrue(recorder.entries.isEmpty)
    }
}
