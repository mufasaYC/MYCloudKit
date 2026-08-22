import CloudKit
import XCTest
@testable import MYCloudKit

final class EncryptedDataResetRecoveryTests: XCTestCase {
    func testPendingZoneResyncIDsPersistAndDeduplicate() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let firstCache = makeCache(at: directoryURL)
        let firstZone = CKRecordZone.ID(zoneName: "Project", ownerName: "owner-a")
        let secondZone = CKRecordZone.ID(zoneName: "Project", ownerName: "owner-b")

        try firstCache.addPendingZoneResyncIDs([firstZone, firstZone, secondZone])

        let restoredCache = makeCache(at: directoryURL)
        XCTAssertEqual(Set(restoredCache.pendingZoneResyncIDs()), Set([firstZone, secondZone]))

        try restoredCache.removePendingZoneResyncIDs([firstZone])
        XCTAssertEqual(makeCache(at: directoryURL).pendingZoneResyncIDs(), [secondZone])

        try restoredCache.removePendingZoneResyncIDs([secondZone])
        XCTAssertTrue(makeCache(at: directoryURL).pendingZoneResyncIDs().isEmpty)
    }

    func testDeletingEncodedSystemFieldsOnlyAffectsResetZone() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let cache = makeCache(at: directoryURL)
        let resetZone = CKRecordZone.ID(zoneName: "Reset", ownerName: "owner")
        let unaffectedZone = CKRecordZone.ID(zoneName: "Unaffected", ownerName: "owner")
        let resetRecord = CKRecord(
            recordType: "Item",
            recordID: .init(recordName: "reset-record", zoneID: resetZone)
        )
        let unaffectedRecord = CKRecord(
            recordType: "Item",
            recordID: .init(recordName: "unaffected-record", zoneID: unaffectedZone)
        )

        cache.saveEncodedSystemFields(
            data: resetRecord.encodedSystemFields,
            for: resetRecord.recordID.recordName
        )
        cache.saveEncodedSystemFields(
            data: unaffectedRecord.encodedSystemFields,
            for: unaffectedRecord.recordID.recordName
        )

        cache.deleteEncodedSystemFields(in: resetZone)

        XCTAssertNil(cache.getEncodedSystemFields(for: resetRecord.recordID.recordName))
        XCTAssertNotNil(cache.getEncodedSystemFields(for: unaffectedRecord.recordID.recordName))
    }

    func testDefaultDelegateImplementationKeepsRecoveryPending() async {
        let delegate = DelegateWithoutRecoveryOptIn()

        let acknowledged = await delegate.didReceiveGroupIDsToResync(["Project"])

        XCTAssertFalse(acknowledged)
    }

    private func makeCache(at directoryURL: URL) -> MYSyncEngine.Cache {
        .init(
            cacheDirectoryURL: directoryURL,
            logger: .init(currentLevel: .none)
        )
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MYCloudKitTests")
            .appendingPathComponent(UUID().uuidString)
    }
}

private final class DelegateWithoutRecoveryOptIn: MYSyncDelegate {
    func didReceiveRecordsToSave(_ records: [MYSyncEngine.FetchedRecord]) async -> Bool {
        true
    }

    func didReceiveRecordsToDelete(
        _ records: [(myRecordID: String, myRecordType: MYRecordType)]
    ) async -> Bool {
        true
    }

    func didReceiveGroupIDsToDelete(_ ids: [String]) async -> Bool {
        true
    }

    func handleUnsyncableRecord(
        recordID: String,
        recordType: MYRecordType,
        reason: String,
        error: Error
    ) -> [any MYRecordConvertible]? {
        nil
    }

    func syncableRecordTypesInDependencyOrder() -> [MYRecordType] {
        ["Item"]
    }
}
