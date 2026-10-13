import CloudKit
import XCTest
@testable import MYCloudKit

final class SyncRetryPolicyTests: XCTestCase {
    private typealias Policy = MYSyncEngine.SyncRetryPolicy

    // MARK: - Classification

    func testAccountWideErrorsPause() {
        for code: CKError.Code in [.quotaExceeded, .notAuthenticated, .accountTemporarilyUnavailable,
                                   .managedAccountRestricted, .badContainer, .badDatabase, .missingEntitlement] {
            guard case .pause(let error) = Policy.kind(of: CKError(code)) else {
                return XCTFail("Expected \(code) to pause")
            }
            XCTAssertEqual(error.code, code)
        }
    }

    func testRetryAfterIsRead() {
        guard case .retryAfter(let seconds) = Policy.kind(of: CKError(.requestRateLimited, retryAfter: 30)) else {
            return XCTFail("Expected retry-after")
        }
        XCTAssertEqual(seconds, 30)
    }

    func testTransientErrorsWithoutHintBackOff() {
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .serverResponseLost,
                                   .zoneBusy, .serviceUnavailable, .requestRateLimited, .operationCancelled] {
            guard case .transient = Policy.kind(of: CKError(code)) else {
                return XCTFail("Expected \(code) to be transient")
            }
        }
    }

    func testOtherErrorsDoNotRetryAutomatically() {
        for error: Error in [CKError(.serverRecordChanged), CKError(.limitExceeded), CKError(.invalidArguments),
                             NSError(domain: "Cannot parse CKRecord", code: 500)] {
            guard case .other = Policy.kind(of: error) else {
                return XCTFail("Expected \(error) to be other")
            }
        }
    }

    func testPartialFailureUsesLargestPerRecordRetryAfter() {
        let error = partialFailure([
            CKError(.zoneBusy, retryAfter: 5),
            CKError(.serviceUnavailable, retryAfter: 42),
            CKError(.networkFailure)
        ])
        guard case .retryAfter(let seconds) = Policy.kind(of: error) else {
            return XCTFail("Expected retry-after")
        }
        XCTAssertEqual(seconds, 42)
    }

    func testPartialFailureWithAccountErrorPauses() {
        let error = partialFailure([CKError(.zoneBusy, retryAfter: 5), CKError(.quotaExceeded)])
        guard case .pause(let pauseError) = Policy.kind(of: error) else {
            return XCTFail("Expected pause")
        }
        XCTAssertEqual(pauseError.code, .quotaExceeded)
    }

    func testMostSignificantErrorPriority() {
        let transient = CKError(.networkFailure)
        let other = CKError(.serverRecordChanged)
        let shortWait = CKError(.zoneBusy, retryAfter: 3)
        let longWait = CKError(.requestRateLimited, retryAfter: 60)
        let quota = CKError(.quotaExceeded)

        XCTAssertEqual(code(Policy.mostSignificantError(in: [transient, other])), .serverRecordChanged)
        XCTAssertEqual(code(Policy.mostSignificantError(in: [other, shortWait, transient])), .zoneBusy)
        XCTAssertEqual(code(Policy.mostSignificantError(in: [shortWait, longWait])), .requestRateLimited)
        XCTAssertEqual(code(Policy.mostSignificantError(in: [longWait, quota, other])), .quotaExceeded)
        XCTAssertNil(Policy.mostSignificantError(in: []))
    }

    func testOnlyPauseAndRetryAfterStopThePass() {
        XCTAssertTrue(Policy.stopsSync(CKError(.quotaExceeded)))
        XCTAssertTrue(Policy.stopsSync(CKError(.zoneBusy, retryAfter: 1)))
        XCTAssertFalse(Policy.stopsSync(CKError(.networkFailure)))
        XCTAssertFalse(Policy.stopsSync(CKError(.serverRecordChanged)))
    }

    // MARK: - Backoff

    func testBackoffDoublesAndCaps() {
        let delays = (1...10).map { Policy.backoffDelay(attempt: $0, randomFactor: 1) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        XCTAssertEqual(Policy.backoffDelay(attempt: 2, randomFactor: 1.2), 4.8, accuracy: 0.0001)
    }

    // MARK: - Retry state

    func testTransientFailuresBackOffAndSuccessResets() {
        var state = MYSyncEngine.SyncRetryState()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(state.recordFailure(CKError(.networkFailure), now: now, randomFactor: 1), .retry(at: now + 2))
        XCTAssertEqual(state.recordFailure(CKError(.networkFailure), now: now, randomFactor: 1), .retry(at: now + 4))
        XCTAssertEqual(state.nextSyncAllowedAt, now + 4)

        state.recordSuccess()
        XCTAssertNil(state.nextSyncAllowedAt)
        XCTAssertEqual(state.consecutiveTransientFailures, 0)
        XCTAssertEqual(state.recordFailure(CKError(.networkFailure), now: now, randomFactor: 1), .retry(at: now + 2))
    }

    func testRetryAfterReplacesBackoff() {
        var state = MYSyncEngine.SyncRetryState()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = state.recordFailure(CKError(.networkFailure), now: now, randomFactor: 100)

        XCTAssertEqual(state.recordFailure(CKError(.zoneBusy, retryAfter: 10), now: now), .retry(at: now + 10))
        XCTAssertEqual(state.nextSyncAllowedAt, now + 10)
    }

    func testOtherFailuresScheduleNothing() {
        var state = MYSyncEngine.SyncRetryState()
        XCTAssertEqual(state.recordFailure(CKError(.serverRecordChanged)), .none)
        XCTAssertNil(state.nextSyncAllowedAt)
    }

    func testResumeClearsPauseAndBackoffButKeepsCloudKitRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_000)

        var paused = MYSyncEngine.SyncRetryState()
        XCTAssertEqual(paused.recordFailure(CKError(.quotaExceeded), now: now), .paused)
        XCTAssertEqual(paused.pauseError?.code, .quotaExceeded)
        paused.resume()
        XCTAssertNil(paused.pauseError)

        var backingOff = MYSyncEngine.SyncRetryState()
        _ = backingOff.recordFailure(CKError(.networkFailure), now: now, randomFactor: 1)
        backingOff.resume()
        XCTAssertNil(backingOff.nextSyncAllowedAt)

        var throttled = MYSyncEngine.SyncRetryState()
        _ = throttled.recordFailure(CKError(.requestRateLimited, retryAfter: 30), now: now)
        throttled.resume()
        XCTAssertEqual(throttled.nextSyncAllowedAt, now + 30)
    }

    // MARK: - Helpers

    private func partialFailure(_ errors: [CKError]) -> CKError {
        var errorsByItemID: [CKRecord.ID: Error] = [:]
        for (index, error) in errors.enumerated() {
            errorsByItemID[CKRecord.ID(recordName: "r\(index)")] = error
        }
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errorsByItemID])
    }

    private func code(_ error: Error?) -> CKError.Code? {
        (error as? CKError)?.code
    }
}

final class LimitExceededSplittingTests: XCTestCase {
    private actor Recorder {
        var requestSizes: [Int] = []
        func record(_ size: Int) { requestSizes.append(size) }
    }

    func testSplitsUntilRequestsFitAndMergesResults() async throws {
        let recorder = Recorder()
        let saves = records(count: 5)
        let deletes = recordIDs(count: 3, prefix: "d")

        let result = try await split(saves, deletes) { saving, deleting in
            await recorder.record(saving.count + deleting.count)
            guard saving.count + deleting.count <= 2 else {
                throw CKError(.limitExceeded)
            }
            return success(saving, deleting)
        }

        XCTAssertEqual(Set(result.saveResults.keys), Set(saves.map(\.recordID)))
        XCTAssertEqual(Set(result.deleteResults.keys), Set(deletes))
        XCTAssertTrue(result.saveResults.values.allSatisfy(isSuccess))
        XCTAssertTrue(result.deleteResults.values.allSatisfy(isSuccess))
        let sizes = await recorder.requestSizes
        XCTAssertEqual(sizes.first, 8)
        XCTAssertTrue(sizes.filter { $0 <= 2 }.reduce(0, +) == 8)
    }

    func testSingleOversizedRecordFailsOnItsOwnWithinSplit() async throws {
        let saves = records(count: 4)
        let oversized = saves[2].recordID

        let result = try await split(saves, []) { saving, deleting in
            if saving.count > 1 || saving.first?.recordID == oversized {
                throw CKError(.limitExceeded)
            }
            return success(saving, deleting)
        }

        XCTAssertEqual(code(result.saveResults[oversized]), .limitExceeded)
        XCTAssertEqual(result.saveResults.values.filter(isSuccess).count, 3)
    }

    func testUnsplitSingleRecordRethrows() async {
        do {
            _ = try await split(records(count: 1), []) { _, _ in throw CKError(.limitExceeded) }
            XCTFail("Expected limitExceeded to be rethrown")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .limitExceeded)
        }
    }

    func testOtherErrorsAreRethrownWithoutSplitting() async {
        let recorder = Recorder()
        do {
            _ = try await split(records(count: 4), []) { saving, _ in
                await recorder.record(saving.count)
                throw CKError(.networkFailure)
            }
            XCTFail("Expected networkFailure to be rethrown")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        let sizes = await recorder.requestSizes
        XCTAssertEqual(sizes, [4])
    }

    func testThrottleMidSplitFailsRemainingHalfWithoutSendingIt() async throws {
        let recorder = Recorder()
        let saves = records(count: 4)
        let deletes = recordIDs(count: 4, prefix: "d")

        let result = try await split(saves, deletes) { saving, deleting in
            await recorder.record(saving.count + deleting.count)
            if saving.count + deleting.count > 4 {
                throw CKError(.limitExceeded)
            }
            throw CKError(.requestRateLimited, retryAfter: 30)
        }

        let sizes = await recorder.requestSizes
        XCTAssertEqual(sizes, [8, 4])
        XCTAssertEqual(result.saveResults.count + result.deleteResults.count, 8)
        XCTAssertTrue(result.saveResults.values.allSatisfy { code($0) == .requestRateLimited })
        XCTAssertTrue(result.deleteResults.values.allSatisfy { code($0) == .requestRateLimited })
    }

    // MARK: - Helpers

    private func split(
        _ saves: [CKRecord],
        _ deletes: [CKRecord.ID],
        modify: ([CKRecord], [CKRecord.ID]) async throws -> MYSyncEngine.ModifyRecordsResult
    ) async throws -> MYSyncEngine.ModifyRecordsResult {
        try await MYSyncEngine.modifyRecordsSplittingOnLimitExceeded(
            saving: saves,
            deleting: deletes,
            logger: .init(currentLevel: .none),
            modify: modify
        )
    }

    private func records(count: Int) -> [CKRecord] {
        recordIDs(count: count, prefix: "s").map { CKRecord(recordType: "Item", recordID: $0) }
    }

    private func recordIDs(count: Int, prefix: String) -> [CKRecord.ID] {
        (0..<count).map { CKRecord.ID(recordName: "\(prefix)\($0)") }
    }

    private func isSuccess<T>(_ result: Result<T, any Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func code<T>(_ result: Result<T, any Error>?) -> CKError.Code? {
        guard case .failure(let error)? = result else { return nil }
        return (error as? CKError)?.code
    }
}

private func success(_ saving: [CKRecord], _ deleting: [CKRecord.ID]) -> MYSyncEngine.ModifyRecordsResult {
    (
        Dictionary(uniqueKeysWithValues: saving.map { ($0.recordID, .success($0)) }),
        Dictionary(uniqueKeysWithValues: deleting.map { ($0, .success(())) })
    )
}

private extension CKError {
    init(_ code: CKError.Code, retryAfter: TimeInterval) {
        self.init(code, userInfo: [CKErrorRetryAfterKey: retryAfter])
    }
}
