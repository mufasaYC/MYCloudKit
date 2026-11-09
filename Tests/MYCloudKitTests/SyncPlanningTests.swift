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

    func testRepeatedSavesUploadTheNewestOnce() {
        let morning = save("x", ["title": .string("Morning")])
        let noon = save("x", ["title": .string("Noon")])
        let evening = save("x", ["title": .string("Evening")])

        let plan = MYSyncEngine.planBatch([morning, noon, evening], using: cache)

        XCTAssertEqual(plan.recordsToSave.count, 1)
        XCTAssertEqual(plan.recordsToSave.first?["title"] as? String, "Evening")
        XCTAssertEqual(plan.recordIDTransactionMap.values.map(\.id), [evening.id])
        XCTAssertEqual(plan.supersededSaves.values.first?.map(\.id), [morning.id, noon.id])
        XCTAssertTrue(plan.completed.isEmpty)
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testRepeatedSavesKeepKeysOnlyAnOlderSaveSet() {
        let first = save("x", ["title": .string("Morning"), "note": .string("Coffee")])
        let second = save("x", ["title": .string("Evening")])

        let plan = MYSyncEngine.planBatch([first, second], using: cache)

        XCTAssertEqual(plan.recordsToSave.first?["title"] as? String, "Evening")
        XCTAssertEqual(plan.recordsToSave.first?["note"] as? String, "Coffee")
    }

    func testRepeatedSavesKeepAValueTheNewestSaveCleared() {
        let first = save("x", ["title": .string("Morning"), "note": .string("Coffee")])
        let second = save("x", ["title": .string("Evening"), "note": .string(nil)])

        let plan = MYSyncEngine.planBatch([first, second], using: cache)

        XCTAssertEqual(plan.recordsToSave.first?["title"] as? String, "Evening")
        XCTAssertNil(plan.recordsToSave.first?["note"])
    }

    func testRepeatedSavesOfDifferentRecordsStaySeparate() {
        let a1 = save("a", ["title": .string("A1")])
        let b1 = save("b", ["title": .string("B1")])
        let a2 = save("a", ["title": .string("A2")])

        let plan = MYSyncEngine.planBatch([a1, b1, a2], using: cache)

        XCTAssertEqual(plan.recordsToSave.map(\.recordID.recordName), ["a", "b"])
        XCTAssertEqual(plan.recordsToSave.map { $0["title"] as? String }, ["A2", "B1"])
        XCTAssertEqual(plan.supersededSaves.count, 1)
    }

    func testDeleteAfterRepeatedSavesCompletesEverySave() {
        let first = save("x", ["title": .string("Morning")])
        let second = save("x", ["title": .string("Evening")])
        let delete = transaction(.deleteRecord, "x")

        let plan = MYSyncEngine.planBatch([first, second, delete], using: cache)

        XCTAssertTrue(plan.recordsToSave.isEmpty)
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["x"])
        XCTAssertEqual(plan.completed.map(\.id), [first.id, second.id])
        XCTAssertTrue(plan.supersededSaves.isEmpty)
    }

    func testRepeatedSavesAfterDeleteAreDeferredTogether() {
        let delete = transaction(.deleteRecord, "x")
        let first = save("x", ["title": .string("Morning")])
        let second = save("x", ["title": .string("Evening")])

        let plan = MYSyncEngine.planBatch([delete, first, second], using: cache)
        XCTAssertEqual(plan.deferred.map(\.id), [first.id, second.id])

        let followUp = MYSyncEngine.planBatch(plan.deferred, using: cache)
        XCTAssertEqual(followUp.recordsToSave.map { $0["title"] as? String }, ["Evening"])
    }

    func testOlderSavesLeaveTheQueueOnlyWithTheNewest() {
        let first = save("x", ["title": .string("Morning")])
        let second = save("x", ["title": .string("Evening")])
        let plan = MYSyncEngine.planBatch([first, second], using: cache)

        // The newest save is still queued (its upload failed and will be retried): keep the older one too.
        XCTAssertTrue(
            MYSyncEngine.supersededSavesToRemove(plan, queuedTransactionIDs: [first.id, second.id]).isEmpty
        )
        // The newest save left the queue (uploaded, or dropped as unsyncable): the older one goes with it.
        XCTAssertEqual(
            MYSyncEngine.supersededSavesToRemove(plan, queuedTransactionIDs: [first.id]).map(\.id),
            [first.id]
        )
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
        _ properties: [String: MYSyncEngine.Transaction.RecordValue?]
    ) -> MYSyncEngine.Transaction {
        .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: "Item", zoneName: "Zone", parentRecordName: nil),
            properties: properties
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
