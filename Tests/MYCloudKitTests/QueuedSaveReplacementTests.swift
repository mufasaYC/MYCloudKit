import CloudKit
import XCTest
@testable import MYCloudKit

/// A record saved again before it uploads replaces its waiting copy, so only the newest is sent.
final class QueuedSaveReplacementTests: XCTestCase {
    private typealias Transaction = MYSyncEngine.Transaction

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

    // MARK: - Queuing

    func testSavingAgainLeavesOnlyTheNewestQueued() {
        let queue = MYSyncEngine.TransactionQueue(cache: cache)
        let morning = save("a", "Morning")
        let afternoon = save("a", "Afternoon")
        let evening = save("a", "Evening")

        XCTAssertEqual(queue.enqueueSaves([morning]), [])
        XCTAssertEqual(queue.enqueueSaves([afternoon]), [morning])
        XCTAssertEqual(queue.enqueueSaves([evening]), [afternoon])

        XCTAssertEqual(queue.snapshot, [evening])
        let plan = MYSyncEngine.planBatch(queue.snapshot, using: cache)
        XCTAssertEqual(plan.recordsToSave.map { $0["title"] as? String }, ["Evening"])
    }

    func testSaveBeingSentIsNotReplaced() {
        let queue = MYSyncEngine.TransactionQueue(cache: cache)
        let morning = save("a", "Morning")
        let afternoon = save("a", "Afternoon")
        let evening = save("a", "Evening")
        _ = queue.enqueueSaves([morning])

        // A sync pass picks up "Morning" and is uploading it.
        let picked = queue.beginSending { _ in true }
        XCTAssertEqual(queue.enqueueSaves([afternoon]), [])
        XCTAssertEqual(queue.enqueueSaves([evening]), [afternoon])
        XCTAssertEqual(queue.snapshot, [morning, evening])

        // Once the pass is done with it, a newer save replaces it as usual.
        queue.finishSending(picked)
        let night = save("a", "Night")
        XCTAssertEqual(queue.enqueueSaves([night]), [morning, evening])
        XCTAssertEqual(queue.snapshot, [night])
    }

    func testNewestSaveGoesAfterADeleteQueuedInBetween() {
        var queue: [Transaction] = []
        let morning = save("a", "Morning")
        let delete = transaction(.deleteRecord, "a")
        let evening = save("a", "Evening")
        _ = MYSyncEngine.TransactionQueue.enqueueSaves([morning], into: &queue, sendingIDs: [])
        queue.append(delete)

        _ = MYSyncEngine.TransactionQueue.enqueueSaves([evening], into: &queue, sendingIDs: [])

        XCTAssertEqual(queue, [delete, evening])
        let plan = MYSyncEngine.planBatch(queue, using: cache)
        XCTAssertEqual(plan.recordsToDelete.map(\.recordName), ["a"])
        XCTAssertEqual(plan.deferred, [evening])
    }

    func testNewestSaveGoesAfterARecordItReferences() {
        var queue: [Transaction] = []
        let morning = save("a", "Morning")
        let folder = save("f", "Folder")
        let evening = save("a", "Evening", references: "f")

        _ = MYSyncEngine.TransactionQueue.enqueueSaves([morning], into: &queue, sendingIDs: [])
        _ = MYSyncEngine.TransactionQueue.enqueueSaves([folder], into: &queue, sendingIDs: [])
        _ = MYSyncEngine.TransactionQueue.enqueueSaves([evening], into: &queue, sendingIDs: [])

        // Past 200 records of a type, batches are sent in queue order: the folder must come first.
        XCTAssertEqual(queue, [folder, evening])
    }

    func testRepeatedSavesInOneCallKeepTheLast() {
        var queue: [Transaction] = []
        let morning = save("a", "Morning")
        let other = save("b", "Other")
        let evening = save("a", "Evening")

        let replaced = MYSyncEngine.TransactionQueue.enqueueSaves(
            [morning, other, evening],
            into: &queue,
            sendingIDs: []
        )

        XCTAssertEqual(queue, [other, evening])
        XCTAssertEqual(replaced, [morning])
    }

    func testOtherRecordsAndOtherZonesAreKept() {
        var queue: [Transaction] = []
        let a = save("a", "A")
        let b = save("b", "B")
        let aInOtherZone = save("a", "A elsewhere", zoneName: "Other")
        let otherType = save("a", "Other type", recordType: "Other")
        _ = MYSyncEngine.TransactionQueue.enqueueSaves([a, b, aInOtherZone, otherType], into: &queue, sendingIDs: [])

        let newestA = save("a", "A2")
        let replaced = MYSyncEngine.TransactionQueue.enqueueSaves([newestA], into: &queue, sendingIDs: [])

        XCTAssertEqual(replaced, [a])
        XCTAssertEqual(queue, [b, aInOtherZone, otherType, newestA])
    }

    func testReplacedSavesStagedAssetsAreRemoved() throws {
        let queue = MYSyncEngine.TransactionQueue(cache: cache)

        // What `MYSyncEngine.sync(_:)` does for each save.
        for version in 1...10 {
            let save = try XCTUnwrap(
                MYSyncEngine.createUpdateTransaction(for: Photo(data: Data("v\(version)".utf8)), using: cache)
            )
            queue.enqueueSaves([save]).forEach { cache.removeCache(for: $0) }
        }

        let folders = try FileManager.default.contentsOfDirectory(
            atPath: directoryURL.appendingPathComponent("transactions").path
        )
        XCTAssertEqual(folders, queue.snapshot.map(\.id.uuidString))
        guard case .asset(let url)?? = queue.snapshot.first?.properties["photo"] else {
            return XCTFail("Expected a staged asset")
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), Data("v10".utf8))
    }

    func testQueuePersistedByEarlierVersionUploadsOnlyTheNewest() {
        // Earlier versions queued every save.
        let saves = [save("a", "Morning"), save("a", "Afternoon"), save("a", "Evening")]

        let plan = MYSyncEngine.planBatch(saves, using: cache)

        XCTAssertEqual(plan.recordsToSave.map { $0["title"] as? String }, ["Evening"])
        XCTAssertEqual(plan.completed.map(\.id), saves.dropLast().map(\.id))
    }

    // MARK: - Helpers

    private func save(
        _ recordName: String,
        _ title: String,
        references: String? = nil,
        zoneName: String = "Zone",
        recordType: String = "Item"
    ) -> Transaction {
        var properties: [String: Transaction.RecordValue?] = ["title": .string(title)]
        if let references {
            properties["folder"] = .reference(
                .init(recordName: references, recordType: "Item", zoneName: zoneName, parentRecordName: nil),
                deleteRule: .none
            )
        }
        return .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: recordType, zoneName: zoneName, parentRecordName: nil),
            properties: properties
        )
    }

    private func transaction(_ operationType: Transaction.OperationType, _ recordName: String) -> Transaction {
        .init(
            id: .init(),
            operationType: operationType,
            record: .init(recordName: recordName, recordType: "Item", zoneName: "Zone", parentRecordName: nil),
            properties: [:]
        )
    }
}

private struct Photo: MYRecordConvertible {
    let data: Data?

    var myRecordID: String { "p1" }
    var myRecordType: String { "Photo" }
    var myRootGroupID: String? { "Zone" }
    var myProperties: [String: MYRecordValue] {
        ["photo": .asset(data), "title": .string("Title")]
    }
}
