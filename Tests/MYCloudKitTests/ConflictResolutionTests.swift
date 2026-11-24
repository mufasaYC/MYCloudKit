import CloudKit
import XCTest
@testable import MYCloudKit

final class ConflictResolutionTests: XCTestCase {
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

    // MARK: - Upload conflicts (`.serverRecordChanged`)

    func testUploadConflictKeepsServerCopyWhenTheDelegateSaysSo() {
        let conflict = saveConflict("x", server: "iPhone new", local: "iPad old")

        let resolution = MYSyncEngine.resolveConflicts([conflict]) { server, local in
            XCTAssertEqual(server.value(for: "text") as String?, "iPhone new")
            XCTAssertEqual(local.value(for: "text") as String?, "iPad old")
            return true
        }

        XCTAssertEqual(resolution.keptServer.map(\.transaction.id), [conflict.transaction.id])
        XCTAssertTrue(resolution.keptLocal.isEmpty)
    }

    func testUploadConflictKeepsLocalCopyWhenTheDelegateSaysSo() {
        let conflict = saveConflict("x", server: "iPad old", local: "iPhone new")

        let resolution = MYSyncEngine.resolveConflicts([conflict]) { _, _ in false }

        XCTAssertTrue(resolution.keptServer.isEmpty)
        XCTAssertEqual(resolution.keptLocal.map(\.transaction.id), [conflict.transaction.id])
    }

    func testUploadConflictWithoutTheLocalCopyKeepsLocalWithoutAsking() {
        let server = ckRecord("x", text: "iPhone new")
        let conflict = MYSyncEngine.SaveConflict(transaction: save("x", "iPad old"), serverRecord: server, localRecord: nil)
        var asked = false

        let resolution = MYSyncEngine.resolveConflicts([conflict]) { _, _ in
            asked = true
            return true
        }

        XCTAssertFalse(asked)
        XCTAssertEqual(resolution.keptLocal.count, 1)
    }

    // MARK: - Fetched records with a save still queued

    func testFetchedRecordWithAQueuedSaveAsksAndDropsTheSavesWhenServerWins() {
        let older = save("x", "Morning")
        let newer = save("x", "iPad old")
        let other = save("y", "Unrelated")
        var askedAbout: [String] = []

        let resolution = MYSyncEngine.resolvePendingSaves(
            for: [ckRecord("x", text: "iPhone new")],
            in: [older, other, newer],
            using: cache
        ) { server, local in
            askedAbout.append(server.id)
            // The newest queued save is the one compared.
            XCTAssertEqual(local.value(for: "text") as String?, "iPad old")
            return true
        }

        XCTAssertEqual(askedAbout, ["x"])
        XCTAssertEqual(resolution.droppedSaves.map(\.id), [older.id, newer.id])
        XCTAssertTrue(resolution.keptLocal.isEmpty)
    }

    func testFetchedRecordWithAQueuedSaveIsKeptFromTheDelegateWhenLocalWins() {
        let queued = save("x", "iPhone new")
        let fetched = ckRecord("x", text: "iPad old")

        let resolution = MYSyncEngine.resolvePendingSaves(for: [fetched], in: [queued], using: cache) { _, _ in false }

        XCTAssertEqual(resolution.keptLocal.map(\.recordID.recordName), ["x"])
        XCTAssertTrue(resolution.droppedSaves.isEmpty)
    }

    func testFetchedRecordsWithNothingQueuedAreNotAskedAbout() {
        let delete = transaction(.deleteRecord, "x")
        var asked = false

        let resolution = MYSyncEngine.resolvePendingSaves(
            for: [ckRecord("x", text: "Hello"), ckRecord("y", text: "Hi")],
            in: [delete],
            using: cache
        ) { _, _ in
            asked = true
            return true
        }

        XCTAssertFalse(asked)
        XCTAssertTrue(resolution.keptLocal.isEmpty)
        XCTAssertTrue(resolution.droppedSaves.isEmpty)
    }

    func testFetchedRecordInAnotherZoneIsNotMatched() {
        let queued = save("x", "Local", zoneName: "Journals")
        var asked = false

        _ = MYSyncEngine.resolvePendingSaves(
            for: [ckRecord("x", text: "Server", zoneName: "Prompts")],
            in: [queued],
            using: cache
        ) { _, _ in
            asked = true
            return true
        }

        XCTAssertFalse(asked)
    }

    func testDelegatesKeepTheirOwnCopyByDefault() {
        let delegate = MinimalDelegate()
        let server = MYSyncEngine.FetchedRecord(record: ckRecord("x", text: "Server"))
        let local = MYSyncEngine.FetchedRecord(record: ckRecord("x", text: "Local"))

        XCTAssertFalse(delegate.shouldKeepServerRecord(server, over: local))
    }

    // MARK: - Helpers

    private func save(_ recordName: String, _ text: String, zoneName: String = "Journals") -> Transaction {
        .init(
            id: .init(),
            operationType: .createOrUpdate,
            record: .init(recordName: recordName, recordType: "Item", zoneName: zoneName, parentRecordName: nil),
            properties: ["text": .string(text)]
        )
    }

    private func transaction(_ operationType: Transaction.OperationType, _ recordName: String) -> Transaction {
        .init(
            id: .init(),
            operationType: operationType,
            record: .init(recordName: recordName, recordType: "Item", zoneName: "Journals", parentRecordName: nil),
            properties: [:]
        )
    }

    private func ckRecord(_ recordName: String, text: String, zoneName: String = "Journals") -> CKRecord {
        let record = CKRecord(
            recordType: "Item",
            recordID: .init(recordName: recordName, zoneID: .init(zoneName: zoneName))
        )
        record["text"] = text
        return record
    }

    private func saveConflict(_ recordName: String, server: String, local: String) -> MYSyncEngine.SaveConflict {
        .init(
            transaction: save(recordName, local),
            serverRecord: ckRecord(recordName, text: server),
            localRecord: ckRecord(recordName, text: local)
        )
    }
}

private final class MinimalDelegate: MYSyncDelegate {
    func didReceiveRecordsToSave(_ records: [MYSyncEngine.FetchedRecord]) async -> Bool { true }
    func didReceiveRecordsToDelete(_ records: [(myRecordID: String, myRecordType: MYRecordType)]) async -> Bool { true }
    func didReceiveGroupIDsToDelete(_ ids: [String]) async -> Bool { true }
    func handleUnsyncableRecord(
        recordID: String,
        recordType: MYRecordType,
        reason: String,
        error: Error
    ) -> [any MYRecordConvertible]? { nil }
    func syncableRecordTypesInDependencyOrder() -> [MYRecordType] { ["Item"] }
}
