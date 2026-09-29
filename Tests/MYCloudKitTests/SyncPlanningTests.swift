import CloudKit
import XCTest
@testable import MYCloudKit

final class SyncPlanningTests: XCTestCase {
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

    func testSaveAfterDeleteIsDeferredUntilDeleteCompletes() {
        let delete = transaction(.deleteRecord, "x")
        let save = transaction(.createOrUpdate, "x")

        let plan = MYSyncEngine.planBatch([delete, save], using: cache)

        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["x"])
        XCTAssertTrue(plan.recordsToSave.isEmpty)
        XCTAssertEqual(plan.deferred, [save])
        XCTAssertTrue(plan.completed.isEmpty)
    }

    func testDeferredSaveIsUploadedInFollowUpPass() {
        let save = transaction(.createOrUpdate, "x")

        let followUp = MYSyncEngine.planBatch([save], using: cache)

        XCTAssertEqual(followUp.recordsToSave.map(\.recordID.recordName), ["x"])
        XCTAssertTrue(followUp.deferred.isEmpty)
    }

    func testDeleteAfterSaveOnlyDeletes() {
        let save = transaction(.createOrUpdate, "x")
        let delete = transaction(.deleteRecord, "x")

        let plan = MYSyncEngine.planBatch([save, delete], using: cache)

        XCTAssertTrue(plan.recordsToSave.isEmpty)
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["x"])
        XCTAssertEqual(plan.completed, [save])
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testRepeatedSavesUploadFirstAndLeaveRestQueued() {
        let first = transaction(.createOrUpdate, "x")
        let second = transaction(.createOrUpdate, "x")

        let plan = MYSyncEngine.planBatch([first, second], using: cache)

        XCTAssertEqual(plan.recordsToSave.count, 1)
        XCTAssertEqual(plan.recordIDTransactionMap.values.map(\.id), [first.id])
        XCTAssertTrue(plan.completed.isEmpty)
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testUnrelatedRecordsAreUnaffected() {
        let saveA = transaction(.createOrUpdate, "a")
        let deleteB = transaction(.deleteRecord, "b")
        let saveC = transaction(.createOrUpdate, "c")

        let plan = MYSyncEngine.planBatch([saveA, deleteB, saveC], using: cache)

        XCTAssertEqual(plan.recordsToSave.map(\.recordID.recordName), ["a", "c"])
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["b"])
        XCTAssertTrue(plan.completed.isEmpty)
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testDeleteWithChildrenThenSaveDefersOnlyTheSave() {
        let deleteChildren = transaction(.deleteChildRecords, "x")
        let delete = transaction(.deleteRecord, "x")
        let save = transaction(.createOrUpdate, "x")

        let plan = MYSyncEngine.planBatch([deleteChildren, delete, save], using: cache)

        XCTAssertEqual(plan.recordsToCascadeDelete.map(\.recordName), ["x"])
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["x"])
        XCTAssertEqual(plan.deferred, [save])
    }

    // MARK: - Helpers

    private func transaction(
        _ operationType: MYSyncEngine.Transaction.OperationType,
        _ recordName: String
    ) -> MYSyncEngine.Transaction {
        .init(
            id: .init(),
            operationType: operationType,
            record: .init(
                recordName: recordName,
                recordType: "Item",
                zoneName: "Zone",
                parentRecordName: nil
            ),
            properties: operationType == .createOrUpdate ? ["title": .string("Title")] : [:]
        )
    }
}
