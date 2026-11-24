import CloudKit
import XCTest
@testable import MYCloudKit

/// iCloud is full: saves are refused, but deletes still go through so the user can free space.
final class ICloudFullTests: XCTestCase {
    private typealias Transaction = MYSyncEngine.Transaction
    private typealias Policy = MYSyncEngine.SyncRetryPolicy

    private var directoryURL: URL!
    private var cache: MYSyncEngine.Cache!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
        cache = .init(cacheDirectoryURL: directoryURL, logger: .init(currentLevel: .none))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    // MARK: - Which error means iCloud is full

    func testQuotaExceededMeansICloudIsFull() {
        XCTAssertTrue(Policy.isICloudFull(CKError(.quotaExceeded)))
    }

    func testPartialFailureWithQuotaExceededMeansICloudIsFull() {
        let error = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "new-entry"): CKError(.quotaExceeded),
                CKRecord.ID(recordName: "other"): CKError(.networkFailure)
            ] as [CKRecord.ID: Error]
        ])

        XCTAssertTrue(Policy.isICloudFull(error))
    }

    func testOtherPausesAndErrorsDontMeanICloudIsFull() {
        for error in [
            CKError(.notAuthenticated),
            CKError(.accountTemporarilyUnavailable),
            CKError(.networkFailure),
            CKError(.serverRecordChanged),
            CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 5.0])
        ] {
            XCTAssertFalse(Policy.isICloudFull(error), "\(error.code)")
        }
        XCTAssertFalse(Policy.isICloudFull(NSError(domain: "Other", code: 1)))
    }

    // MARK: - What is sent while iCloud is full

    func testOnlyDeletesAreSentAndSavesStayQueued() {
        let newEntry = transaction(.createOrUpdate, "new-entry")
        let deletedEntry = transaction(.deleteRecord, "old-entry")
        let edit = transaction(.createOrUpdate, "edited-entry")
        let deletedPhoto = transaction(.deleteRecord, "old-photo")

        let toSend = MYSyncEngine.transactionsToSendWhileICloudIsFull([newEntry, deletedEntry, edit, deletedPhoto])

        XCTAssertEqual(toSend, [deletedEntry, deletedPhoto])
    }

    func testSaveFollowedByADeleteOfTheSameRecordIsSentAndOnlyDeletes() {
        let save = transaction(.createOrUpdate, "photo")
        let delete = transaction(.deleteRecord, "photo")

        let toSend = MYSyncEngine.transactionsToSendWhileICloudIsFull([save, delete])
        let plan = MYSyncEngine.planBatch(toSend, using: cache)

        XCTAssertEqual(toSend, [save, delete])
        // Nothing is uploaded: the save is completed with the delete, so it can't re-create the record later.
        XCTAssertTrue(plan.recordsToSave.isEmpty)
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["photo"])
        XCTAssertEqual(plan.completed, [save])
    }

    func testSaveAfterTheDeleteStaysQueued() {
        let delete = transaction(.deleteRecord, "x")
        let recreate = transaction(.createOrUpdate, "x")

        XCTAssertEqual(MYSyncEngine.transactionsToSendWhileICloudIsFull([delete, recreate]), [delete])
    }

    func testOnlyTheSavesBeforeTheLastDeleteAreSent() {
        let first = transaction(.createOrUpdate, "x")
        let delete = transaction(.deleteRecord, "x")
        let recreate = transaction(.createOrUpdate, "x")

        XCTAssertEqual(MYSyncEngine.transactionsToSendWhileICloudIsFull([first, delete, recreate]), [first, delete])
    }

    func testChildDeletesAreSentAndZoneDeletesStayQueued() {
        let children = transaction(.deleteChildRecords, "folder")
        let folder = transaction(.deleteRecord, "folder")
        let zone = transaction(.deleteZone, "zone-marker")

        XCTAssertEqual(MYSyncEngine.transactionsToSendWhileICloudIsFull([children, folder, zone]), [children, folder])
    }

    func testDeleteInAnotherZoneDoesntSendTheSave() {
        let save = transaction(.createOrUpdate, "x", zoneName: "Journals")
        let delete = transaction(.deleteRecord, "x", zoneName: "Prompts")

        XCTAssertEqual(MYSyncEngine.transactionsToSendWhileICloudIsFull([save, delete]), [delete])
    }

    // MARK: - Helpers

    private func transaction(
        _ operationType: Transaction.OperationType,
        _ recordName: String,
        zoneName: String = "Journals"
    ) -> Transaction {
        .init(
            id: .init(),
            operationType: operationType,
            record: .init(recordName: recordName, recordType: "Item", zoneName: zoneName, parentRecordName: nil),
            properties: [:]
        )
    }
}
