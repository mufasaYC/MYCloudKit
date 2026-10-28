import XCTest
@testable import MYCloudKit

@MainActor
final class FetchCoalescingTests: XCTestCase {

    func testRequestsMadeMidFetchRunOneMorePass() async {
        let coalescer = MYSyncEngine.FetchCoalescer()
        var passes = 0

        await coalescer.run {
            passes += 1
            if passes == 1 {
                // Two silent pushes arriving while this pass runs.
                await coalescer.run { XCTFail("a pass must not run alongside another") }
                await coalescer.run { XCTFail("a pass must not run alongside another") }
            }
        }

        XCTAssertEqual(passes, 2)
    }

    func testRequestDuringTheExtraPassRunsAnotherOne() async {
        let coalescer = MYSyncEngine.FetchCoalescer()
        var passes = 0

        await coalescer.run {
            passes += 1
            if passes < 3 {
                await coalescer.run { XCTFail("a pass must not run alongside another") }
            }
        }

        XCTAssertEqual(passes, 3)
    }

    func testFetchWithoutRequestsMidFetchRunsOnce() async {
        let coalescer = MYSyncEngine.FetchCoalescer()
        var passes = 0

        await coalescer.run { passes += 1 }
        await coalescer.run { passes += 1 }

        XCTAssertEqual(passes, 2, "back-to-back requests each run their own pass")
    }
}
