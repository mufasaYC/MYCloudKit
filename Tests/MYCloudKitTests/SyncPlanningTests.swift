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

    func testRepeatedSavesUploadOnlyTheNewest() {
        let morning = save("x", "Morning")
        let afternoon = save("x", "Afternoon")
        let evening = save("x", "Evening")

        let plan = MYSyncEngine.planBatch([morning, afternoon, evening], using: cache)

        XCTAssertEqual(plan.recordsToSave.map { $0["title"] as? String }, ["Evening"])
        XCTAssertEqual(plan.recordIDTransactionMap.values.map(\.id), [evening.id])
        // The older saves leave the queue with this pass; if the newest fails, it alone is retried.
        XCTAssertEqual(plan.completed.map(\.id), [morning.id, afternoon.id])
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testNewestSaveIsUploadedAsIsWithoutOlderValues() {
        let older = save("x", "Morning", extra: ["note": .string("Coffee")])
        let newest = save("x", "Evening")

        let plan = MYSyncEngine.planBatch([older, newest], using: cache)

        XCTAssertEqual(plan.recordsToSave.first?["title"] as? String, "Evening")
        XCTAssertNil(plan.recordsToSave.first?["note"])
    }

    func testRepeatedSavesOfDifferentRecordsStaySeparate() {
        let a1 = save("a", "A1")
        let b1 = save("b", "B1")
        let a2 = save("a", "A2")

        let plan = MYSyncEngine.planBatch([a1, b1, a2], using: cache)

        XCTAssertEqual(plan.recordsToSave.map(\.recordID.recordName), ["a", "b"])
        XCTAssertEqual(plan.recordsToSave.map { $0["title"] as? String }, ["A2", "B1"])
        XCTAssertEqual(plan.completed.map(\.id), [a1.id])
    }

    func testDeleteAfterRepeatedSavesOnlyDeletes() {
        let morning = save("x", "Morning")
        let evening = save("x", "Evening")
        let delete = transaction(.deleteRecord, "x")

        let plan = MYSyncEngine.planBatch([morning, evening, delete], using: cache)

        XCTAssertTrue(plan.recordsToSave.isEmpty)
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["x"])
        XCTAssertEqual(plan.completed.map(\.id), [morning.id, evening.id])
    }

    func testRepeatedSavesAfterDeleteUploadTheNewestInFollowUpPass() {
        let delete = transaction(.deleteRecord, "x")
        let morning = save("x", "Morning")
        let evening = save("x", "Evening")

        let plan = MYSyncEngine.planBatch([delete, morning, evening], using: cache)
        XCTAssertEqual(plan.deferred.map(\.id), [morning.id, evening.id])

        let followUp = MYSyncEngine.planBatch(plan.deferred, using: cache)
        XCTAssertEqual(followUp.recordsToSave.map { $0["title"] as? String }, ["Evening"])
        XCTAssertEqual(followUp.completed.map(\.id), [morning.id])
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

    private func save(
        _ recordName: String,
        _ title: String,
        extra: [String: MYSyncEngine.Transaction.RecordValue?] = [:]
    ) -> MYSyncEngine.Transaction {
        .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: "Item", zoneName: "Zone", parentRecordName: nil),
            properties: extra.merging(["title": .string(title)]) { $1 }
        )
    }

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
